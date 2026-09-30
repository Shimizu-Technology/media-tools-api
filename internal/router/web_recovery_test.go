package router

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
)

func postWebRecovery(t *testing.T, engine *gin.Engine, path string, body any, cookies []*http.Cookie, origin, csrf string) *httptest.ResponseRecorder {
	t.Helper()
	payload, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(payload))
	req.Header.Set("Content-Type", "application/json")
	if origin != "" {
		req.Header.Set("Origin", origin)
	}
	if csrf != "" {
		req.Header.Set(middleware.WebCSRFHeader, csrf)
	}
	for _, cookie := range cookies {
		req.AddCookie(cookie)
	}
	response := httptest.NewRecorder()
	engine.ServeHTTP(response, req)
	return response
}

func TestWebRecoverySignInAndRotationCookieFlow(t *testing.T) {
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	db, err := database.New(url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if err := db.RunMigrations("../../migrations"); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	insertUser := func(name string) string {
		t.Helper()
		var id string
		if err := db.QueryRowContext(ctx, `INSERT INTO users (email, password_hash, name) VALUES ($1, '', $2) RETURNING id`, uuid.NewString()+"@example.com", name).Scan(&id); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, id) })
		return id
	}
	oldUserID := insertUser("Old browser user")
	targetUserID := insertUser("Recovered browser user")
	oldSession, err := db.CreateFirstPartySession(ctx, oldUserID, "web", "Old browser")
	if err != nil {
		t.Fatal(err)
	}
	rotation, err := db.BeginRecoveryCodeRotation(ctx, targetUserID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.ConfirmRecoveryCodeRotation(ctx, targetUserID, rotation.ID); err != nil {
		t.Fatal(err)
	}

	const origin = "https://media.example.com"
	engine := Setup(RouterConfig{DB: db, FirstPartyAuthEnabled: true, WebCookieAuthEnabled: true, WebCookieSecure: true, AllowedOrigins: []string{origin}})
	preparePath := "/api/v1/auth/web/session/recovery/prepare"
	finishPath := "/api/v1/auth/web/session/recovery/finish"

	wrongOrigin := postWebRecovery(t, engine, preparePath, map[string]any{}, nil, "https://attacker.example.com", "")
	if wrongOrigin.Code != http.StatusForbidden {
		t.Fatalf("wrong origin prepare = %d", wrongOrigin.Code)
	}
	prepare := postWebRecovery(t, engine, preparePath, map[string]any{}, []*http.Cookie{
		{Name: middleware.WebRefreshCookie, Value: oldSession.RefreshToken},
	}, origin, "")
	if prepare.Code != http.StatusNoContent || prepare.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("prepare = %d: %s", prepare.Code, prepare.Body.String())
	}
	pending := cookieByName(prepare.Result().Cookies(), middleware.WebRecoveryPendingCookie)
	csrf := cookieByName(prepare.Result().Cookies(), middleware.WebCSRFCookie)
	if pending == nil || !pending.HttpOnly || pending.Path != "/api/v1/auth/web/session" || csrf == nil || csrf.HttpOnly {
		t.Fatalf("prepare cookies = %#v", prepare.Result().Cookies())
	}
	for _, cookie := range prepare.Result().Cookies() {
		if cookie.Name == middleware.WebRefreshCookie && cookie.MaxAge < 0 {
			t.Fatal("prepare cleared the existing session before redemption")
		}
	}
	baseCookies := []*http.Cookie{pending, csrf, {Name: middleware.WebRefreshCookie, Value: oldSession.RefreshToken}}
	badCSRF := postWebRecovery(t, engine, finishPath, map[string]any{"code": rotation.Codes[0]}, baseCookies, origin, "wrong")
	if badCSRF.Code != http.StatusForbidden {
		t.Fatalf("bad CSRF finish = %d", badCSRF.Code)
	}
	invalid := postWebRecovery(t, engine, finishPath, map[string]any{"code": "MTR-INVALID"}, baseCookies, origin, csrf.Value)
	if invalid.Code != http.StatusUnauthorized || !strings.Contains(invalid.Body.String(), "invalid_recovery_code") {
		t.Fatalf("invalid code = %d: %s", invalid.Code, invalid.Body.String())
	}
	if cookie := cookieByName(invalid.Result().Cookies(), middleware.WebRecoveryPendingCookie); cookie != nil && cookie.MaxAge < 0 {
		t.Fatal("wrong code cleared usable successor")
	}

	finish := postWebRecovery(t, engine, finishPath, map[string]any{"code": rotation.Codes[0]}, baseCookies, origin, csrf.Value)
	if finish.Code != http.StatusCreated || bytes.Contains(finish.Body.Bytes(), []byte("access_token")) || bytes.Contains(finish.Body.Bytes(), []byte("refresh_token")) {
		t.Fatalf("finish leaked credentials = %d: %s", finish.Code, finish.Body.String())
	}
	access := cookieByName(finish.Result().Cookies(), middleware.WebAccessCookie)
	refresh := cookieByName(finish.Result().Cookies(), middleware.WebRefreshCookie)
	newCSRF := cookieByName(finish.Result().Cookies(), middleware.WebCSRFCookie)
	if access == nil || refresh == nil || refresh.Value != pending.Value || newCSRF == nil {
		t.Fatalf("finish cookies = %#v", finish.Result().Cookies())
	}
	if _, _, err := db.GetUserByFirstPartyAccessToken(ctx, oldSession.AccessToken); !errors.Is(err, database.ErrSessionInvalid) {
		t.Fatalf("old session remained active: %v", err)
	}

	// The response-loss retry uses the original prepared jar. The code can be
	// omitted because the HttpOnly successor identifies the committed issuance.
	retry := postWebRecovery(t, engine, finishPath, map[string]any{}, baseCookies, origin, csrf.Value)
	if retry.Code != http.StatusCreated || bytes.Contains(retry.Body.Bytes(), []byte("access_token")) || cookieByName(retry.Result().Cookies(), middleware.WebRefreshCookie).Value != pending.Value {
		t.Fatalf("lost-response retry = %d: %s", retry.Code, retry.Body.String())
	}

	// Cookie-authenticated management keeps the old set active until confirm.
	currentCookies := []*http.Cookie{access, refresh, newCSRF}
	statusReq := httptest.NewRequest(http.MethodGet, "/api/v1/auth/recovery", nil)
	for _, cookie := range currentCookies {
		statusReq.AddCookie(cookie)
	}
	status := httptest.NewRecorder()
	engine.ServeHTTP(status, statusReq)
	if status.Code != http.StatusOK || status.Body.String() != `{"remaining":9}` {
		t.Fatalf("cookie status = %d: %s", status.Code, status.Body.String())
	}
	beginPath := "/api/v1/auth/recovery/rotation/begin"
	confirmPath := "/api/v1/auth/recovery/rotation/confirm"
	if response := postWebRecovery(t, engine, beginPath, map[string]any{}, currentCookies, origin, "wrong"); response.Code != http.StatusForbidden {
		t.Fatalf("management CSRF = %d", response.Code)
	}
	begin := postWebRecovery(t, engine, beginPath, map[string]any{}, currentCookies, origin, newCSRF.Value)
	replacement := readRecoveryRotation(t, begin.Code, begin.Body.Bytes(), begin.Header().Get("Cache-Control"))
	oldNext := newTestRefreshToken(t)
	if _, err := db.RedeemRecoveryCode(ctx, rotation.Codes[1], "ios", "Phone", oldNext); err != nil {
		t.Fatalf("old set stopped before confirm: %v", err)
	}
	confirm := postWebRecovery(t, engine, confirmPath, map[string]any{"rotation_id": replacement.RotationID}, currentCookies, origin, newCSRF.Value)
	if confirm.Code != http.StatusOK || confirm.Body.String() != `{"remaining":10}` {
		t.Fatalf("confirm = %d: %s", confirm.Code, confirm.Body.String())
	}
	confirmRetry := postWebRecovery(t, engine, confirmPath, map[string]any{"rotation_id": replacement.RotationID}, currentCookies, origin, newCSRF.Value)
	if confirmRetry.Code != http.StatusOK || confirmRetry.Body.String() != `{"remaining":10}` {
		t.Fatalf("confirm retry = %d: %s", confirmRetry.Code, confirmRetry.Body.String())
	}
	if _, err := db.RedeemRecoveryCode(ctx, rotation.Codes[2], "ios", "Phone", newTestRefreshToken(t)); !errors.Is(err, database.ErrRecoveryCodeInvalid) {
		t.Fatalf("old set active after confirm: %v", err)
	}
	if _, err := db.RedeemRecoveryCode(ctx, replacement.Codes[0], "ios", "Phone", newTestRefreshToken(t)); err != nil {
		t.Fatalf("replacement not active: %v", err)
	}
	logout := postWebRecovery(t, engine, "/api/v1/auth/web/session/logout", map[string]any{}, baseCookies, origin, csrf.Value)
	if logout.Code != http.StatusNoContent {
		t.Fatalf("logout after lost recovery response = %d: %s", logout.Code, logout.Body.String())
	}
	if _, _, err := db.GetUserByFirstPartyAccessToken(ctx, access.Value); !errors.Is(err, database.ErrSessionInvalid) {
		t.Fatalf("logout did not revoke recovery-pending session: %v", err)
	}

	disabled := Setup(RouterConfig{DB: db, AllowedOrigins: []string{origin}})
	for _, path := range []string{preparePath, finishPath} {
		if response := postWebRecovery(t, disabled, path, map[string]any{}, nil, origin, ""); response.Code != http.StatusNotFound {
			t.Fatalf("disabled %s = %d", path, response.Code)
		}
	}
}

func TestWebRecoveryStaleSuccessorClearsOnlyPendingAndPreservesCode(t *testing.T) {
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	db, err := database.New(url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if err := db.RunMigrations("../../migrations"); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	var userID string
	if err := db.QueryRowContext(ctx, `INSERT INTO users (email, password_hash, name) VALUES ($1, '', 'Stale Recovery') RETURNING id`, uuid.NewString()+"@example.com").Scan(&userID); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, userID) })
	rotation, err := db.BeginRecoveryCodeRotation(ctx, userID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.ConfirmRecoveryCodeRotation(ctx, userID, rotation.ID); err != nil {
		t.Fatal(err)
	}
	existing, err := db.CreateFirstPartySession(ctx, userID, "web", "Existing browser")
	if err != nil {
		t.Fatal(err)
	}
	const origin = "https://media.example.com"
	engine := Setup(RouterConfig{DB: db, FirstPartyAuthEnabled: true, WebCookieAuthEnabled: true, WebCookieSecure: true, AllowedOrigins: []string{origin}})
	csrf := &http.Cookie{Name: middleware.WebCSRFCookie, Value: "csrf-stale"}
	stalePending := &http.Cookie{Name: middleware.WebRecoveryPendingCookie, Value: existing.RefreshToken}
	existingRefresh := &http.Cookie{Name: middleware.WebRefreshCookie, Value: existing.RefreshToken}
	finishPath := "/api/v1/auth/web/session/recovery/finish"
	stale := postWebRecovery(t, engine, finishPath, map[string]any{"code": rotation.Codes[0]}, []*http.Cookie{csrf, stalePending, existingRefresh}, origin, csrf.Value)
	if stale.Code != http.StatusBadRequest || !strings.Contains(stale.Body.String(), "sign_in_not_prepared") {
		t.Fatalf("stale successor = %d: %s", stale.Code, stale.Body.String())
	}
	clearedPending := false
	for _, cookie := range stale.Result().Cookies() {
		if cookie.Name == middleware.WebRecoveryPendingCookie && cookie.MaxAge < 0 {
			clearedPending = true
		}
		if cookie.Name == middleware.WebRefreshCookie && cookie.MaxAge < 0 {
			t.Fatal("stale successor cleared the existing browser session")
		}
	}
	if !clearedPending {
		t.Fatal("stale recovery successor was not cleared")
	}
	if remaining, err := db.RemainingRecoveryCodes(ctx, userID); err != nil || remaining != 10 {
		t.Fatalf("stale successor consumed code: remaining=%d err=%v", remaining, err)
	}
	if _, _, err := db.GetUserByFirstPartyAccessToken(ctx, existing.AccessToken); err != nil {
		t.Fatalf("stale successor revoked existing session: %v", err)
	}

	prepare := postWebRecovery(t, engine, "/api/v1/auth/web/session/recovery/prepare", map[string]any{}, []*http.Cookie{existingRefresh}, origin, "")
	freshPending := cookieByName(prepare.Result().Cookies(), middleware.WebRecoveryPendingCookie)
	freshCSRF := cookieByName(prepare.Result().Cookies(), middleware.WebCSRFCookie)
	if prepare.Code != http.StatusNoContent || freshPending == nil || freshPending.Value == existing.RefreshToken || freshCSRF == nil {
		t.Fatalf("fresh prepare = %d %#v", prepare.Code, prepare.Result().Cookies())
	}
	retry := postWebRecovery(t, engine, finishPath, map[string]any{"code": rotation.Codes[0]}, []*http.Cookie{freshPending, freshCSRF, existingRefresh}, origin, freshCSRF.Value)
	if retry.Code != http.StatusCreated {
		t.Fatalf("same code with fresh successor = %d: %s", retry.Code, retry.Body.String())
	}
	if remaining, err := db.RemainingRecoveryCodes(ctx, userID); err != nil || remaining != 9 {
		t.Fatalf("fresh retry remaining=%d err=%v", remaining, err)
	}
}
