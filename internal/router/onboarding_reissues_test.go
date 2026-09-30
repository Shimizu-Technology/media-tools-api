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
)

func TestOnboardingReissueHTTPIsAdminOnlyAndNativeSafe(t *testing.T) {
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
	var userID string
	if err := db.QueryRowContext(context.Background(), `
		INSERT INTO users (email, password_hash, name)
		VALUES ($1, '', 'Rescue Person') RETURNING id`, uuid.NewString()+"@example.com").Scan(&userID); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, userID) })
	const adminKey = "test-admin-key-that-is-at-least-32-chars"
	engine := Setup(RouterConfig{DB: db, FirstPartyAuthEnabled: true, AdminAPIKey: adminKey})
	createPath := "/api/v1/auth/onboarding/reissues"
	redeemPath := "/api/v1/auth/onboarding/reissues/redeem"

	if response := postInvitationJSON(t, engine, createPath, map[string]any{"user_id": userID}, ""); response.Code != http.StatusUnauthorized {
		t.Fatalf("missing admin key status = %d: %s", response.Code, response.Body.String())
	}
	create := postInvitationJSON(t, engine, createPath, map[string]any{"user_id": userID}, adminKey)
	if create.Code != http.StatusCreated || create.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("create onboarding rescue = %d: %s", create.Code, create.Body.String())
	}
	var created struct {
		Token   string `json:"token"`
		JoinURL string `json:"join_url"`
	}
	if err := json.Unmarshal(create.Body.Bytes(), &created); err != nil ||
		!strings.HasPrefix(created.Token, "mta_onb_") ||
		created.JoinURL != "https://media.shimizu-technology.com/join#onboarding="+created.Token {
		t.Fatalf("create onboarding rescue body = %#v, %v", created, err)
	}
	next, err := database.RandomFirstPartyRefreshToken()
	if err != nil {
		t.Fatal(err)
	}
	web := postPasskeyJSON(t, engine, redeemPath, map[string]any{
		"token": created.Token, "client_type": "web", "device_name": "Browser", "next_refresh_token": next,
	}, "")
	if web.Code != http.StatusBadRequest || strings.Contains(web.Body.String(), "access_token") || strings.Contains(web.Body.String(), "refresh_token") {
		t.Fatalf("raw web onboarding rescue leaked credentials = %d: %s", web.Code, web.Body.String())
	}
	native := postPasskeyJSON(t, engine, redeemPath, map[string]any{
		"token": created.Token, "client_type": "ios", "device_name": "iPhone", "next_refresh_token": next,
	}, "")
	if native.Code != http.StatusCreated || native.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("native onboarding rescue = %d: %s", native.Code, native.Body.String())
	}
	var pair database.AuthTokenPair
	if err := json.Unmarshal(native.Body.Bytes(), &pair); err != nil || pair.UserID != userID || pair.RefreshToken != next {
		t.Fatalf("native onboarding rescue pair = %#v, %v", pair, err)
	}
}
