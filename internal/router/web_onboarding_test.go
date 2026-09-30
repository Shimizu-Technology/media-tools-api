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

	"github.com/google/uuid"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
)

func getWebOnboarding(t *testing.T, engine http.Handler, path string, cookies ...*http.Cookie) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, path, nil)
	for _, cookie := range cookies {
		if cookie != nil {
			req.AddCookie(cookie)
		}
	}
	response := httptest.NewRecorder()
	engine.ServeHTTP(response, req)
	return response
}

func TestWebInvitationOnboardingCookieProtocolAndDurableCompletion(t *testing.T) {
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	db, err := database.NewWithSimpleProtocol(databaseURL, true)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if err := db.RunMigrations("../../migrations"); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	invitation, token, err := db.CreateInvitation(ctx, uuid.NewString()+"@example.com", "Web invited person")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE email = $1`, invitation.Email)
		_, _ = db.ExecContext(context.Background(), `DELETE FROM auth_invitations WHERE id = $1`, invitation.ID)
	})
	const origin = "https://media.example.com"
	engine := Setup(RouterConfig{DB: db, FirstPartyAuthEnabled: true, WebCookieAuthEnabled: true, WebCookieSecure: true, AllowedOrigins: []string{origin}})
	base := "/api/v1/auth/web/onboarding"

	wrongOrigin := postWebRecovery(t, engine, base+"/transfer", map[string]any{"kind": "invite", "token": token}, nil, "https://attacker.example.com", "")
	if wrongOrigin.Code != http.StatusForbidden {
		t.Fatalf("wrong origin transfer = %d", wrongOrigin.Code)
	}
	transfer := postWebRecovery(t, engine, base+"/transfer", map[string]any{"kind": "invite", "token": token}, nil, origin, "")
	if transfer.Code != http.StatusNoContent || transfer.Body.Len() != 0 || transfer.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("transfer = %d %q", transfer.Code, transfer.Body.String())
	}
	inviteCookie := cookieByName(transfer.Result().Cookies(), middleware.WebInvitationCookie)
	pending := cookieByName(transfer.Result().Cookies(), middleware.WebOnboardingPendingCookie)
	csrf := cookieByName(transfer.Result().Cookies(), middleware.WebCSRFCookie)
	for _, cookie := range []*http.Cookie{inviteCookie, pending} {
		if cookie == nil || cookie.Domain != "" || !cookie.Secure || !cookie.HttpOnly || cookie.SameSite != http.SameSiteStrictMode || cookie.Path != base || cookie.MaxAge != 15*60 {
			t.Fatalf("unsafe onboarding cookie: %+v", cookie)
		}
	}
	if inviteCookie.Value != token || csrf == nil || csrf.HttpOnly || csrf.Path != "/" {
		t.Fatalf("transfer cookies = %#v", transfer.Result().Cookies())
	}
	transferCookies := []*http.Cookie{inviteCookie, pending, csrf}
	status := getWebOnboarding(t, engine, base+"/status", transferCookies...)
	if status.Code != http.StatusOK || !strings.Contains(status.Body.String(), `"pending":true`) || strings.Contains(status.Body.String(), token) {
		t.Fatalf("pending status = %d: %s", status.Code, status.Body.String())
	}
	if rejected := postWebRecovery(t, engine, base+"/commit", map[string]any{}, transferCookies, origin, "wrong"); rejected.Code != http.StatusForbidden {
		t.Fatalf("commit without matching CSRF = %d", rejected.Code)
	}
	commit := postWebRecovery(t, engine, base+"/commit", map[string]any{}, transferCookies, origin, csrf.Value)
	if commit.Code != http.StatusCreated || bytes.Contains(commit.Body.Bytes(), []byte("access_token")) || bytes.Contains(commit.Body.Bytes(), []byte("refresh_token")) || bytes.Contains(commit.Body.Bytes(), []byte(token)) {
		t.Fatalf("commit leaked credential = %d: %s", commit.Code, commit.Body.String())
	}
	access := cookieByName(commit.Result().Cookies(), middleware.WebAccessCookie)
	refresh := cookieByName(commit.Result().Cookies(), middleware.WebRefreshCookie)
	newCSRF := cookieByName(commit.Result().Cookies(), middleware.WebCSRFCookie)
	if access == nil || refresh == nil || refresh.Value != pending.Value || newCSRF == nil {
		t.Fatalf("commit cookies = %#v", commit.Result().Cookies())
	}
	var committed struct {
		UserID string `json:"user_id"`
	}
	if err := json.Unmarshal(commit.Body.Bytes(), &committed); err != nil || committed.UserID == "" {
		t.Fatalf("commit metadata = %#v, %v", committed, err)
	}
	// Simulate losing every Set-Cookie header. The exact original secret and
	// successor recover the committed session without creating another account.
	retry := postWebRecovery(t, engine, base+"/commit", map[string]any{}, transferCookies, origin, csrf.Value)
	if retry.Code != http.StatusCreated || cookieByName(retry.Result().Cookies(), middleware.WebRefreshCookie).Value != pending.Value {
		t.Fatalf("lost response retry = %d: %s", retry.Code, retry.Body.String())
	}

	// The requirement is stored on the account. Deleting or expiring the hint
	// cookie cannot unlock the app or allow another link to strand this account.
	activeCookies := []*http.Cookie{access, refresh, newCSRF}
	withoutHint := getWebOnboarding(t, engine, base+"/status", activeCookies...)
	if withoutHint.Code != http.StatusOK || !strings.Contains(withoutHint.Body.String(), `"onboarding_required":true`) {
		t.Fatalf("server requirement missing without hint cookie = %d: %s", withoutHint.Code, withoutHint.Body.String())
	}
	second, secondToken, err := db.CreateInvitation(ctx, uuid.NewString()+"@example.com", "Second account")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = db.ExecContext(context.Background(), `DELETE FROM auth_invitations WHERE id = $1`, second.ID)
	})
	blockedSwitch := postWebRecovery(t, engine, base+"/transfer", map[string]any{"kind": "invite", "token": secondToken}, activeCookies, origin, "")
	if blockedSwitch.Code != http.StatusConflict || !strings.Contains(blockedSwitch.Body.String(), "onboarding_in_progress") {
		t.Fatalf("second link replaced required account = %d: %s", blockedSwitch.Code, blockedSwitch.Body.String())
	}
	var consumed bool
	if err := db.GetContext(ctx, &consumed, `SELECT consumed_at IS NOT NULL FROM auth_invitations WHERE id = $1`, second.ID); err != nil || consumed {
		t.Fatalf("blocked second link was consumed = %v, %v", consumed, err)
	}
	ordinary := getWebOnboarding(t, engine, "/api/v1/transcripts", access)
	if ordinary.Code != http.StatusPreconditionRequired || !strings.Contains(ordinary.Body.String(), "onboarding_required") {
		t.Fatalf("ordinary API bypassed onboarding = %d: %s", ordinary.Code, ordinary.Body.String())
	}
	incomplete := postWebRecovery(t, engine, base+"/complete", map[string]any{}, activeCookies, origin, newCSRF.Value)
	if incomplete.Code != http.StatusConflict {
		t.Fatalf("completion without factors = %d: %s", incomplete.Code, incomplete.Body.String())
	}
	if _, err := db.ExecContext(ctx, `INSERT INTO auth_passkey_credentials (credential_id, user_id, credential) VALUES ($1, $2, '{}')`, []byte("router-passkey-"+uuid.NewString()), committed.UserID); err != nil {
		t.Fatal(err)
	}
	rotation, err := db.BeginRecoveryCodeRotation(ctx, committed.UserID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.ConfirmRecoveryCodeRotation(ctx, committed.UserID, rotation.ID); err != nil {
		t.Fatal(err)
	}
	complete := postWebRecovery(t, engine, base+"/complete", map[string]any{}, activeCookies, origin, newCSRF.Value)
	if complete.Code != http.StatusNoContent {
		t.Fatalf("completion = %d: %s", complete.Code, complete.Body.String())
	}
	completedStatus := getWebOnboarding(t, engine, base+"/status", activeCookies...)
	if completedStatus.Code != http.StatusOK || strings.Contains(completedStatus.Body.String(), `"onboarding_required":true`) {
		t.Fatalf("completed server state = %d: %s", completedStatus.Code, completedStatus.Body.String())
	}
}

func TestWebOnboardingStaleSuccessorPreservesLinkAndOldSession(t *testing.T) {
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	db, err := database.NewWithSimpleProtocol(databaseURL, true)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if err := db.RunMigrations("../../migrations"); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	var oldUserID string
	if err := db.QueryRowContext(ctx, `INSERT INTO users (email, password_hash, name) VALUES ($1, '', 'Old account') RETURNING id`, uuid.NewString()+"@example.com").Scan(&oldUserID); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, oldUserID) })
	oldSession, err := db.CreateFirstPartySession(ctx, oldUserID, "web", "Old browser")
	if err != nil {
		t.Fatal(err)
	}
	invitation, token, err := db.CreateInvitation(ctx, uuid.NewString()+"@example.com", "Fresh account")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE email = $1`, invitation.Email)
		_, _ = db.ExecContext(context.Background(), `DELETE FROM auth_invitations WHERE id = $1`, invitation.ID)
	})
	const origin = "https://media.example.com"
	const base = "/api/v1/auth/web/onboarding"
	engine := Setup(RouterConfig{DB: db, FirstPartyAuthEnabled: true, WebCookieAuthEnabled: true, WebCookieSecure: true, AllowedOrigins: []string{origin}})
	csrf := &http.Cookie{Name: middleware.WebCSRFCookie, Value: "csrf-stale"}
	invite := &http.Cookie{Name: middleware.WebInvitationCookie, Value: token}
	stale := &http.Cookie{Name: middleware.WebOnboardingPendingCookie, Value: oldSession.RefreshToken}
	refresh := &http.Cookie{Name: middleware.WebRefreshCookie, Value: oldSession.RefreshToken}
	commit := postWebRecovery(t, engine, base+"/commit", map[string]any{}, []*http.Cookie{csrf, invite, stale, refresh}, origin, csrf.Value)
	if commit.Code != http.StatusBadRequest || !strings.Contains(commit.Body.String(), "onboarding_not_prepared") {
		t.Fatalf("stale successor = %d: %s", commit.Code, commit.Body.String())
	}
	var cleared *http.Cookie
	for _, cookie := range commit.Result().Cookies() {
		if cookie.Name == middleware.WebOnboardingPendingCookie {
			cleared = cookie
		}
	}
	if cleared == nil || cleared.MaxAge >= 0 {
		t.Fatalf("stale successor not cleared: %#v", commit.Result().Cookies())
	}
	if cookie := cookieByName(commit.Result().Cookies(), middleware.WebInvitationCookie); cookie != nil && cookie.MaxAge < 0 {
		t.Fatal("stale successor cleared the unconsumed invitation")
	}
	if user, _, err := db.GetUserByFirstPartyAccessToken(ctx, oldSession.AccessToken); err != nil || user.ID != oldUserID {
		t.Fatalf("stale successor stranded prior account: %#v, %v", user, err)
	}
	prepare := postWebRecovery(t, engine, base+"/prepare", map[string]any{}, []*http.Cookie{invite, refresh}, origin, "")
	fresh := cookieByName(prepare.Result().Cookies(), middleware.WebOnboardingPendingCookie)
	freshCSRF := cookieByName(prepare.Result().Cookies(), middleware.WebCSRFCookie)
	if prepare.Code != http.StatusNoContent || fresh == nil || fresh.Value == oldSession.RefreshToken || freshCSRF == nil {
		t.Fatalf("fresh prepare = %d: %#v", prepare.Code, prepare.Result().Cookies())
	}
	retry := postWebRecovery(t, engine, base+"/commit", map[string]any{}, []*http.Cookie{invite, fresh, freshCSRF, refresh}, origin, freshCSRF.Value)
	if retry.Code != http.StatusCreated {
		t.Fatalf("same link with fresh successor = %d: %s", retry.Code, retry.Body.String())
	}
	if _, _, err := db.GetUserByFirstPartyAccessToken(ctx, oldSession.AccessToken); !errors.Is(err, database.ErrSessionInvalid) {
		t.Fatalf("successful account switch kept prior session: %v", err)
	}
}

func TestWebOnboardingRoutesRequireBothFlags(t *testing.T) {
	const origin = "https://media.example.com"
	for _, cfg := range []RouterConfig{
		{FirstPartyAuthEnabled: true, AllowedOrigins: []string{origin}},
		{WebCookieAuthEnabled: true, AllowedOrigins: []string{origin}},
	} {
		engine := Setup(cfg)
		for _, path := range []string{"/transfer", "/prepare", "/commit", "/status", "/complete"} {
			response := postWebRecovery(t, engine, "/api/v1/auth/web/onboarding"+path, map[string]any{}, nil, origin, "")
			if response.Code != http.StatusNotFound {
				t.Fatalf("flags off %s = %d", path, response.Code)
			}
		}
	}
}
