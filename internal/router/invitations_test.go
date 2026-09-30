package router

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
)

func TestInvitationCreateAndRedeemHTTP(t *testing.T) {
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
	engine := Setup(RouterConfig{
		DB:                    db,
		FirstPartyAuthEnabled: true,
		AdminAPIKey:           "test-admin-key-that-is-at-least-32-chars",
	})
	createPath := "/api/v1/auth/invitations"
	redeemPath := "/api/v1/auth/invitations/redeem"

	noKey := postPasskeyJSON(t, engine, createPath, map[string]any{"email": uuid.NewString() + "@example.com", "name": "No Key"}, "")
	if noKey.Code != http.StatusUnauthorized {
		t.Fatalf("missing admin key status = %d", noKey.Code)
	}
	email := uuid.NewString() + "@example.com"
	create := postInvitationJSON(t, engine, createPath, map[string]any{"email": email, "name": "Invited Person"}, "test-admin-key-that-is-at-least-32-chars")
	if create.Code != http.StatusCreated || create.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("create invitation status = %d: %s", create.Code, create.Body.String())
	}
	var body struct {
		InviteURL string `json:"invite_url"`
		Token     string `json:"token"`
	}
	if err := json.Unmarshal(create.Body.Bytes(), &body); err != nil || !strings.Contains(body.InviteURL, "/join#invite=mta_inv_") {
		t.Fatalf("invitation response = %#v, %v", body, err)
	}
	token := strings.TrimPrefix(body.InviteURL, "https://media.shimizu-technology.com/join#invite=")
	if token == body.InviteURL || token != body.Token {
		t.Fatalf("invitation token/link mismatch: %#v", body)
	}
	redeem := postPasskeyJSON(t, engine, redeemPath, map[string]any{"token": token, "client_type": "web", "device_name": "Browser"}, "")
	if redeem.Code != http.StatusCreated || redeem.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("redeem invitation status = %d: %s", redeem.Code, redeem.Body.String())
	}
	var pair database.AuthTokenPair
	if err := json.Unmarshal(redeem.Body.Bytes(), &pair); err != nil || pair.UserID == "" || pair.RefreshToken == "" {
		t.Fatalf("redeem pair = %#v, %v", pair, err)
	}
	t.Cleanup(func() { _, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, pair.UserID) })
	if replay := postPasskeyJSON(t, engine, redeemPath, map[string]any{"token": token, "client_type": "web"}, ""); replay.Code != http.StatusUnauthorized {
		t.Fatalf("replayed invitation status = %d", replay.Code)
	}
	if conflict := postInvitationJSON(t, engine, createPath, map[string]any{"email": email, "name": "Duplicate"}, "test-admin-key-that-is-at-least-32-chars"); conflict.Code != http.StatusConflict {
		t.Fatalf("existing email invitation status = %d", conflict.Code)
	}
}

func TestInvitationRoutesDisabledWithoutFirstPartyFlag(t *testing.T) {
	engine := Setup(RouterConfig{AdminAPIKey: "test-admin-key-that-is-at-least-32-chars"})
	if response := postInvitationJSON(t, engine, "/api/v1/auth/invitations", map[string]any{"email": uuid.NewString() + "@example.com", "name": "Disabled"}, "test-admin-key-that-is-at-least-32-chars"); response.Code != http.StatusNotFound {
		t.Fatalf("disabled invitation create status = %d", response.Code)
	}
	if response := postPasskeyJSON(t, engine, "/api/v1/auth/invitations/redeem", map[string]any{"token": "mta_inv_invalid", "client_type": "web"}, ""); response.Code != http.StatusNotFound {
		t.Fatalf("disabled invitation redeem status = %d", response.Code)
	}
}

func postInvitationJSON(t *testing.T, engine http.Handler, path string, body any, adminKey string) *httptest.ResponseRecorder {
	t.Helper()
	data, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(string(data)))
	req.Header.Set("Content-Type", "application/json")
	if adminKey != "" {
		req.Header.Set("X-Admin-Key", adminKey)
	}
	response := httptest.NewRecorder()
	engine.ServeHTTP(response, req)
	return response
}
