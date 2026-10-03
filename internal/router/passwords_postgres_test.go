package router

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	accountservice "github.com/Shimizu-Technology/media-tools-api/internal/services/account"
)

func TestPasswordNativeAndWebLoginFlows(t *testing.T) {
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
	email := uuid.NewString() + "@example.com"
	if err := db.QueryRowContext(ctx, `INSERT INTO users (email, password_hash, name) VALUES ($1, '', 'Password HTTP') RETURNING id`, email).Scan(&userID); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, userID) })
	hasher, _ := accountservice.NewPasswordHasher(1)
	hash, _ := hasher.Hash(ctx, "a secure password for http tests")
	bootstrap, err := db.CreateFirstPartySession(ctx, userID, "ios", "Bootstrap")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.SetPasswordCredential(ctx, userID, bootstrap.SessionID, hash); err != nil {
		t.Fatal(err)
	}
	oldBrowser, err := db.CreateFirstPartySession(ctx, userID, "web", "Existing browser")
	if err != nil {
		t.Fatal(err)
	}

	const origin = "https://media.example.com"
	engine := Setup(RouterConfig{DB: db, FirstPartyAuthEnabled: true, FirstPartyPasswordAuthEnabled: true, WebCookieAuthEnabled: true, WebCookieSecure: true, AllowedOrigins: []string{origin}})
	nativeSuccessor, _ := database.RandomFirstPartyRefreshToken()
	native := postWebRecovery(t, engine, "/api/v1/auth/password/login", map[string]any{
		"email": email, "password": "a secure password for http tests", "client_type": "ios", "device_name": "Test iPhone", "next_refresh_token": nativeSuccessor,
	}, nil, "", "")
	if native.Code != http.StatusCreated || !bytes.Contains(native.Body.Bytes(), []byte(nativeSuccessor)) {
		t.Fatalf("native password login = %d: %s", native.Code, native.Body.String())
	}
	wrong := postWebRecovery(t, engine, "/api/v1/auth/password/login", map[string]any{
		"email": "unknown@example.com", "password": "wrong password", "client_type": "ios", "device_name": "Test", "next_refresh_token": nativeSuccessor,
	}, nil, "", "")
	if wrong.Code != http.StatusUnauthorized || !strings.Contains(wrong.Body.String(), "invalid_credentials") {
		t.Fatalf("unknown password login = %d: %s", wrong.Code, wrong.Body.String())
	}

	oldAccessCookie := &http.Cookie{Name: middleware.WebAccessCookie, Value: oldBrowser.AccessToken}
	oldRefreshCookie := &http.Cookie{Name: middleware.WebRefreshCookie, Value: oldBrowser.RefreshToken}
	prepare := postWebRecovery(t, engine, "/api/v1/auth/web/session/password/prepare", map[string]any{}, []*http.Cookie{oldAccessCookie, oldRefreshCookie}, origin, "")
	if prepare.Code != http.StatusNoContent {
		t.Fatalf("web prepare = %d: %s", prepare.Code, prepare.Body.String())
	}
	pending := cookieByName(prepare.Result().Cookies(), middleware.WebPasswordPendingCookie)
	csrf := cookieByName(prepare.Result().Cookies(), middleware.WebCSRFCookie)
	if pending == nil || csrf == nil || !pending.HttpOnly || csrf.HttpOnly {
		t.Fatalf("web prepare cookies = %#v", prepare.Result().Cookies())
	}
	wrongWeb := postWebRecovery(t, engine, "/api/v1/auth/web/session/password/finish", map[string]any{
		"email": email, "password": "the wrong password",
	}, []*http.Cookie{oldAccessCookie, oldRefreshCookie, pending, csrf}, origin, csrf.Value)
	if wrongWeb.Code != http.StatusUnauthorized {
		t.Fatalf("wrong web password = %d: %s", wrongWeb.Code, wrongWeb.Body.String())
	}
	if _, _, err := db.GetUserByFirstPartyAccessToken(ctx, oldBrowser.AccessToken); err != nil {
		t.Fatalf("prepare or rejected password revoked existing browser: %v", err)
	}
	finish := postWebRecovery(t, engine, "/api/v1/auth/web/session/password/finish", map[string]any{
		"email": email, "password": "a secure password for http tests",
	}, []*http.Cookie{oldAccessCookie, oldRefreshCookie, pending, csrf}, origin, csrf.Value)
	if finish.Code != http.StatusCreated || bytes.Contains(finish.Body.Bytes(), []byte("access_token")) || bytes.Contains(finish.Body.Bytes(), []byte("refresh_token")) {
		t.Fatalf("web finish = %d: %s", finish.Code, finish.Body.String())
	}
	access := cookieByName(finish.Result().Cookies(), middleware.WebAccessCookie)
	refresh := cookieByName(finish.Result().Cookies(), middleware.WebRefreshCookie)
	if access == nil || refresh == nil || refresh.Value != pending.Value {
		t.Fatalf("web finish cookies = %#v", finish.Result().Cookies())
	}
	if _, _, err := db.GetUserByFirstPartyAccessToken(ctx, access.Value); err != nil {
		t.Fatalf("web access cookie: %v", err)
	}
	if _, _, err := db.GetUserByFirstPartyAccessToken(ctx, oldBrowser.AccessToken); !errors.Is(err, database.ErrSessionInvalid) {
		t.Fatalf("replaced browser session survived successful sign-in: %v", err)
	}
	// A browser that missed the first response still has the old cookie jar.
	// Retrying the exact request recovers the same replacement session.
	recovered := postWebRecovery(t, engine, "/api/v1/auth/web/session/password/finish", map[string]any{
		"email": email, "password": "a secure password for http tests",
	}, []*http.Cookie{oldAccessCookie, oldRefreshCookie, pending, csrf}, origin, csrf.Value)
	if recovered.Code != http.StatusCreated {
		t.Fatalf("recover web password response = %d: %s", recovered.Code, recovered.Body.String())
	}
	recoveredRefresh := cookieByName(recovered.Result().Cookies(), middleware.WebRefreshCookie)
	if recoveredRefresh == nil || recoveredRefresh.Value != refresh.Value {
		t.Fatalf("recovered web session changed refresh credential: %#v", recovered.Result().Cookies())
	}

	// A password change through the current browser session keeps that browser
	// alive while revoking the separately signed-in native device.
	change := postWebRecovery(t, engine, "/api/v1/auth/password", map[string]any{"password": "a replacement password for http tests"}, []*http.Cookie{access, csrf}, origin, csrf.Value)
	if change.Code != http.StatusOK {
		t.Fatalf("change password = %d: %s", change.Code, change.Body.String())
	}
	if _, _, err := db.GetUserByFirstPartyAccessToken(ctx, access.Value); err != nil {
		t.Fatalf("current browser revoked: %v", err)
	}
	var nativePair database.AuthTokenPair
	if err := json.Unmarshal(native.Body.Bytes(), &nativePair); err != nil {
		t.Fatal(err)
	}
	if _, _, err := db.GetUserByFirstPartyAccessToken(ctx, nativePair.AccessToken); !errors.Is(err, database.ErrSessionInvalid) {
		t.Fatalf("other device survived password change: %v", err)
	}
}
