package router

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"testing"

	"github.com/google/uuid"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

func TestRecoveryCodesIssueRotateAndRedeemHTTP(t *testing.T) {
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
	issuePath := "/api/v1/auth/recovery"
	redeemPath := "/api/v1/auth/recovery/redeem"
	legacy, err := middleware.GenerateJWT(&models.User{ID: userID, Email: "legacy@example.com"}, "test-only")
	if err != nil {
		t.Fatal(err)
	}
	if response := postPasskeyJSON(t, engine, issuePath, map[string]any{}, legacy); response.Code != http.StatusUnauthorized {
		t.Fatalf("legacy JWT issued codes: %d", response.Code)
	}
	if response := postPasskeyJSON(t, engine, issuePath, map[string]any{}, ""); response.Code != http.StatusUnauthorized {
		t.Fatalf("anonymous code issue: %d", response.Code)
	}
	issued := postPasskeyJSON(t, engine, issuePath, map[string]any{}, session.AccessToken)
	if issued.Code != http.StatusCreated || issued.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("issue response = %d: %s", issued.Code, issued.Body.String())
	}
	var first struct {
		Codes []string `json:"codes"`
	}
	if err := json.Unmarshal(issued.Body.Bytes(), &first); err != nil || len(first.Codes) != 10 {
		t.Fatalf("issued codes = %#v, %v", first, err)
	}
	count, err := db.RemainingRecoveryCodes(ctx, userID)
	if err != nil || count != 10 {
		t.Fatalf("remaining codes = %d, %v", count, err)
	}
	invalid := postPasskeyJSON(t, engine, redeemPath, map[string]any{"code": "MTR-INVALID", "client_type": "web"}, "")
	if invalid.Code != http.StatusUnauthorized {
		t.Fatalf("invalid code response = %d", invalid.Code)
	}
	redeem := postPasskeyJSON(t, engine, redeemPath, map[string]any{"code": first.Codes[0], "client_type": "ios", "device_name": "Replacement iPhone"}, "")
	if redeem.Code != http.StatusCreated || redeem.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("redeem response = %d: %s", redeem.Code, redeem.Body.String())
	}
	var recovered database.AuthTokenPair
	if err := json.Unmarshal(redeem.Body.Bytes(), &recovered); err != nil || recovered.UserID != userID || recovered.AccessToken == "" || recovered.RefreshToken == "" {
		t.Fatalf("recovered pair = %#v, %v", recovered, err)
	}
	if response := postPasskeyJSON(t, engine, redeemPath, map[string]any{"code": first.Codes[0], "client_type": "ios"}, ""); response.Code != http.StatusUnauthorized {
		t.Fatalf("replayed code = %d", response.Code)
	}
	if count, err := db.RemainingRecoveryCodes(ctx, userID); err != nil || count != 9 {
		t.Fatalf("remaining after redeem = %d, %v", count, err)
	}
	rotated := postPasskeyJSON(t, engine, issuePath, map[string]any{}, recovered.AccessToken)
	if rotated.Code != http.StatusCreated {
		t.Fatalf("rotate response = %d: %s", rotated.Code, rotated.Body.String())
	}
	if response := postPasskeyJSON(t, engine, redeemPath, map[string]any{"code": first.Codes[1], "client_type": "ios"}, ""); response.Code != http.StatusUnauthorized {
		t.Fatalf("invalidated old code = %d", response.Code)
	}
	if response := postPasskeyJSON(t, Setup(RouterConfig{DB: db, JWTSecret: "test-only"}), redeemPath, map[string]any{"code": first.Codes[1], "client_type": "ios"}, ""); response.Code != http.StatusNotFound {
		t.Fatalf("disabled recovery route = %d", response.Code)
	}
}
