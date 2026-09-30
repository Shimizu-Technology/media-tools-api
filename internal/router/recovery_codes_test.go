package router

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

type recoveryRotationResponse struct {
	RotationID string   `json:"rotation_id"`
	Codes      []string `json:"codes"`
}

func readRecoveryRotation(t *testing.T, responseCode int, responseBody []byte, cacheControl string) recoveryRotationResponse {
	t.Helper()
	if responseCode != http.StatusCreated || cacheControl != "no-store" {
		t.Fatalf("begin response = %d, cache=%q: %s", responseCode, cacheControl, responseBody)
	}
	var rotation recoveryRotationResponse
	if err := json.Unmarshal(responseBody, &rotation); err != nil || uuid.Validate(rotation.RotationID) != nil || len(rotation.Codes) != 10 {
		t.Fatalf("begin response = %#v, %v", rotation, err)
	}
	return rotation
}

func TestRecoveryCodeRotationAndRedemptionHTTP(t *testing.T) {
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
	if err := db.QueryRowContext(ctx, `INSERT INTO users (email, password_hash, name) VALUES ($1, '', 'Recovery Test') RETURNING id`, uuid.NewString()+"@example.com").Scan(&userID); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, userID) })
	session, err := db.CreateFirstPartySession(ctx, userID, "ios", "Current iPhone")
	if err != nil {
		t.Fatal(err)
	}
	engine := Setup(RouterConfig{DB: db, FirstPartyAuthEnabled: true, JWTSecret: "test-only"})
	statusPath := "/api/v1/auth/recovery"
	beginPath := "/api/v1/auth/recovery/rotation/begin"
	confirmPath := "/api/v1/auth/recovery/rotation/confirm"
	redeemPath := "/api/v1/auth/recovery/redeem"
	legacy, err := middleware.GenerateJWT(&models.User{ID: userID, Email: "legacy@example.com"}, "test-only")
	if err != nil {
		t.Fatal(err)
	}

	for _, path := range []string{beginPath, confirmPath} {
		if response := postPasskeyJSON(t, engine, path, map[string]any{"rotation_id": uuid.NewString()}, legacy); response.Code != http.StatusUnauthorized {
			t.Fatalf("legacy JWT used %s: %d", path, response.Code)
		}
		if response := postPasskeyJSON(t, engine, path, map[string]any{"rotation_id": uuid.NewString()}, ""); response.Code != http.StatusUnauthorized {
			t.Fatalf("anonymous request used %s: %d", path, response.Code)
		}
	}
	if response := postPasskeyJSON(t, engine, statusPath, map[string]any{}, session.AccessToken); response.Code != http.StatusNotFound {
		t.Fatalf("removed destructive issue route = %d: %s", response.Code, response.Body.String())
	}
	status := getPasskeyJSON(t, engine, statusPath, session.AccessToken)
	if status.Code != http.StatusOK || status.Header().Get("Cache-Control") != "no-store" || status.Body.String() != `{"remaining":0}` {
		t.Fatalf("initial status = %d: %s", status.Code, status.Body.String())
	}

	begin := postPasskeyJSON(t, engine, beginPath, map[string]any{}, session.AccessToken)
	first := readRecoveryRotation(t, begin.Code, begin.Body.Bytes(), begin.Header().Get("Cache-Control"))
	if status := getPasskeyJSON(t, engine, statusPath, session.AccessToken); status.Code != http.StatusOK || status.Body.String() != `{"remaining":0}` {
		t.Fatalf("pending set changed status = %d: %s", status.Code, status.Body.String())
	}
	pendingNext := newTestRefreshToken(t)
	if response := postPasskeyJSON(t, engine, redeemPath, map[string]any{"code": first.Codes[0], "client_type": "ios", "next_refresh_token": pendingNext}, ""); response.Code != http.StatusUnauthorized {
		t.Fatalf("pending code redeemed = %d: %s", response.Code, response.Body.String())
	}
	confirm := postPasskeyJSON(t, engine, confirmPath, map[string]any{"rotation_id": first.RotationID}, session.AccessToken)
	if confirm.Code != http.StatusOK || confirm.Header().Get("Cache-Control") != "no-store" || confirm.Body.String() != `{"remaining":10}` {
		t.Fatalf("confirm response = %d: %s", confirm.Code, confirm.Body.String())
	}
	if retry := postPasskeyJSON(t, engine, confirmPath, map[string]any{"rotation_id": first.RotationID}, session.AccessToken); retry.Code != http.StatusOK || retry.Body.String() != `{"remaining":10}` {
		t.Fatalf("lost confirm retry = %d: %s", retry.Code, retry.Body.String())
	}

	next := newTestRefreshToken(t)
	invalid := postPasskeyJSON(t, engine, redeemPath, map[string]any{"code": "MTR-INVALID", "client_type": "ios", "next_refresh_token": next}, "")
	if invalid.Code != http.StatusUnauthorized {
		t.Fatalf("invalid code response = %d", invalid.Code)
	}
	web := postPasskeyJSON(t, engine, redeemPath, map[string]any{"code": first.Codes[0], "client_type": "web", "next_refresh_token": next}, "")
	if web.Code != http.StatusBadRequest || strings.Contains(web.Body.String(), "access_token") || strings.Contains(web.Body.String(), "refresh_token") {
		t.Fatalf("raw web recovery leaked credentials = %d: %s", web.Code, web.Body.String())
	}
	redeem := postPasskeyJSON(t, engine, redeemPath, map[string]any{"code": first.Codes[0], "client_type": "ios", "device_name": "Replacement iPhone", "next_refresh_token": next}, "")
	if redeem.Code != http.StatusCreated || redeem.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("redeem response = %d: %s", redeem.Code, redeem.Body.String())
	}
	var recovered database.AuthTokenPair
	if err := json.Unmarshal(redeem.Body.Bytes(), &recovered); err != nil || recovered.UserID != userID || recovered.AccessToken == "" || recovered.RefreshToken != next {
		t.Fatalf("recovered pair = %#v, %v", recovered, err)
	}
	retry := postPasskeyJSON(t, engine, redeemPath, map[string]any{"code": first.Codes[0], "client_type": "ios", "next_refresh_token": next}, "")
	var retried database.AuthTokenPair
	if retry.Code != http.StatusCreated || json.Unmarshal(retry.Body.Bytes(), &retried) != nil ||
		retried.SessionID != recovered.SessionID || retried.RefreshToken != next || retried.AccessToken == recovered.AccessToken {
		t.Fatalf("exact recovery retry = %d %#v: %s", retry.Code, retried, retry.Body.String())
	}
	wrong := newTestRefreshToken(t)
	if response := postPasskeyJSON(t, engine, redeemPath, map[string]any{"code": first.Codes[0], "client_type": "ios", "next_refresh_token": wrong}, ""); response.Code != http.StatusUnauthorized || strings.Contains(response.Body.String(), "access_token") || strings.Contains(response.Body.String(), "refresh_token") {
		t.Fatalf("wrong recovery successor = %d: %s", response.Code, response.Body.String())
	}
	if status := getPasskeyJSON(t, engine, statusPath, recovered.AccessToken); status.Code != http.StatusOK || status.Body.String() != `{"remaining":9}` {
		t.Fatalf("status after redemption = %d: %s", status.Code, status.Body.String())
	}

	secondBegin := postPasskeyJSON(t, engine, beginPath, map[string]any{}, recovered.AccessToken)
	second := readRecoveryRotation(t, secondBegin.Code, secondBegin.Body.Bytes(), secondBegin.Header().Get("Cache-Control"))
	oldNext := newTestRefreshToken(t)
	if response := postPasskeyJSON(t, engine, redeemPath, map[string]any{"code": first.Codes[1], "client_type": "android", "next_refresh_token": oldNext}, ""); response.Code != http.StatusCreated {
		t.Fatalf("old code failed before confirmation = %d: %s", response.Code, response.Body.String())
	}
	if response := postPasskeyJSON(t, engine, confirmPath, map[string]any{"rotation_id": second.RotationID}, recovered.AccessToken); response.Code != http.StatusOK || response.Body.String() != `{"remaining":10}` {
		t.Fatalf("second confirmation = %d: %s", response.Code, response.Body.String())
	}
	if response := postPasskeyJSON(t, engine, redeemPath, map[string]any{"code": first.Codes[2], "client_type": "ios", "next_refresh_token": newTestRefreshToken(t)}, ""); response.Code != http.StatusUnauthorized {
		t.Fatalf("old code remained active = %d", response.Code)
	}
	if response := postPasskeyJSON(t, engine, redeemPath, map[string]any{"code": second.Codes[0], "client_type": "ios", "next_refresh_token": newTestRefreshToken(t)}, ""); response.Code != http.StatusCreated {
		t.Fatalf("new code did not activate = %d: %s", response.Code, response.Body.String())
	}

	disabled := Setup(RouterConfig{DB: db, JWTSecret: "test-only"})
	for _, path := range []string{statusPath, beginPath, confirmPath, redeemPath} {
		var responseCode int
		if path == statusPath {
			responseCode = getPasskeyJSON(t, disabled, path, session.AccessToken).Code
		} else {
			responseCode = postPasskeyJSON(t, disabled, path, map[string]any{}, session.AccessToken).Code
		}
		if responseCode != http.StatusNotFound {
			t.Fatalf("disabled route %s = %d", path, responseCode)
		}
	}
}
