package router

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

func TestUnknownAPIRouteUsesErrorContractAndRequestID(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := Setup(RouterConfig{Version: "test-build"})

	request := httptest.NewRequest(http.MethodGet, "/api/v1/does-not-exist", nil)
	response := httptest.NewRecorder()
	router.ServeHTTP(response, request)

	if response.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusNotFound)
	}
	if response.Header().Get("X-Request-ID") == "" {
		t.Fatal("response is missing X-Request-ID")
	}

	var body models.ErrorResponse
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body.Error != "not_found" || body.Message != "Endpoint not found" || body.Code != http.StatusNotFound {
		t.Fatalf("response = %#v, want standard not_found error", body)
	}
}

func TestFirstPartyBearerAndRefreshHTTP(t *testing.T) {
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	db, err := database.New(databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if err := db.RunMigrations("../../migrations"); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	var userID string
	if err := db.QueryRowContext(ctx, `INSERT INTO users (email, password_hash) VALUES ($1, '') RETURNING id`, uuid.NewString()+"@example.com").Scan(&userID); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, userID) })
	pair, err := db.CreateFirstPartySession(ctx, userID, "ios", "Test iPhone")
	if err != nil {
		t.Fatal(err)
	}
	engine := Setup(RouterConfig{DB: db, FirstPartyAuthEnabled: true})

	me := httptest.NewRequest(http.MethodGet, "/api/v1/auth/me", nil)
	me.Header.Set("Authorization", "Bearer "+pair.AccessToken)
	result := httptest.NewRecorder()
	engine.ServeHTTP(result, me)
	if result.Code != http.StatusOK {
		t.Fatalf("first-party /auth/me status = %d: %s", result.Code, result.Body.String())
	}
	var user models.User
	if err := json.Unmarshal(result.Body.Bytes(), &user); err != nil || user.ID != userID {
		t.Fatalf("first-party /auth/me user = %#v, %v", user, err)
	}

	refresh := httptest.NewRequest(http.MethodPost, "/api/v1/auth/session/refresh", nil)
	refresh.Header.Set("Content-Type", "application/json")
	refresh.Body = http.NoBody
	invalid := httptest.NewRecorder()
	engine.ServeHTTP(invalid, refresh)
	if invalid.Code != http.StatusBadRequest {
		t.Fatalf("missing refresh credential status = %d", invalid.Code)
	}
	validRefresh := httptest.NewRequest(http.MethodPost, "/api/v1/auth/session/refresh", strings.NewReader(`{"refresh_token":"`+pair.RefreshToken+`"}`))
	validRefresh.Header.Set("Content-Type", "application/json")
	refreshed := httptest.NewRecorder()
	engine.ServeHTTP(refreshed, validRefresh)
	if refreshed.Code != http.StatusOK || refreshed.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("refresh status = %d, cache = %q: %s", refreshed.Code, refreshed.Header().Get("Cache-Control"), refreshed.Body.String())
	}
	var newPair database.AuthTokenPair
	if err := json.Unmarshal(refreshed.Body.Bytes(), &newPair); err != nil || newPair.RefreshToken == pair.RefreshToken {
		t.Fatalf("refresh response = %#v, %v", newPair, err)
	}
	malformed := httptest.NewRequest(http.MethodPost, "/api/v1/auth/session/refresh", strings.NewReader(`{"refresh_token":"`+newPair.RefreshToken+`","next_refresh_token":"bad"}`))
	malformed.Header.Set("Content-Type", "application/json")
	malformedResult := httptest.NewRecorder()
	engine.ServeHTTP(malformedResult, malformed)
	if malformedResult.Code != http.StatusBadRequest {
		t.Fatalf("malformed successor status = %d", malformedResult.Code)
	}

	// A client that persisted its successor before sending can safely retry
	// the exact same request if the first HTTP response was lost.
	clientNext, err := database.RandomFirstPartyRefreshToken()
	if err != nil {
		t.Fatal(err)
	}
	body := `{"refresh_token":"` + newPair.RefreshToken + `","next_refresh_token":"` + clientNext + `"}`
	for attempt := 0; attempt < 2; attempt++ {
		request := httptest.NewRequest(http.MethodPost, "/api/v1/auth/session/refresh", strings.NewReader(body))
		request.Header.Set("Content-Type", "application/json")
		response := httptest.NewRecorder()
		engine.ServeHTTP(response, request)
		if response.Code != http.StatusOK {
			t.Fatalf("recovery attempt %d status = %d: %s", attempt, response.Code, response.Body.String())
		}
		var recovered database.AuthTokenPair
		if err := json.Unmarshal(response.Body.Bytes(), &recovered); err != nil || recovered.RefreshToken != clientNext {
			t.Fatalf("recovery attempt %d pair = %#v, %v", attempt, recovered, err)
		}
	}
}

func TestLegacyBearerAcceptanceFollowsExplicitFlagWithoutJWKS(t *testing.T) {
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	db, err := database.New(databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if err := db.RunMigrations("../../migrations"); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	var userID string
	if err := db.QueryRowContext(ctx, `INSERT INTO users (email, password_hash) VALUES ($1, '') RETURNING id`, uuid.NewString()+"@example.com").Scan(&userID); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, userID) })
	secret := "legacy-test-secret"
	token, err := middleware.GenerateJWT(&models.User{ID: userID, Email: "legacy@example.com"}, secret)
	if err != nil {
		t.Fatal(err)
	}

	request := func(engine http.Handler, path string) int {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		req.Header.Set("Authorization", "Bearer "+token)
		response := httptest.NewRecorder()
		engine.ServeHTTP(response, req)
		return response.Code
	}
	enabled := Setup(RouterConfig{DB: db, JWTSecret: secret, LegacyAuthEnabled: true})
	if got := request(enabled, "/api/v1/auth/me"); got != http.StatusOK {
		t.Fatalf("legacy-enabled user route = %d", got)
	}
	if got := request(enabled, "/api/v1/transcripts"); got != http.StatusOK {
		t.Fatalf("legacy-enabled protected route = %d", got)
	}

	disabled := Setup(RouterConfig{DB: db, JWTSecret: secret})
	if got := request(disabled, "/api/v1/auth/me"); got != http.StatusUnauthorized {
		t.Fatalf("legacy-disabled user route = %d", got)
	}
	if got := request(disabled, "/api/v1/transcripts"); got != http.StatusUnauthorized {
		t.Fatalf("legacy-disabled protected route = %d", got)
	}
	firstPartyOnly := Setup(RouterConfig{DB: db, JWTSecret: secret, FirstPartyAuthEnabled: true})
	if got := request(firstPartyOnly, "/api/v1/auth/me"); got != http.StatusUnauthorized {
		t.Fatalf("first-party mode accepted legacy bearer = %d", got)
	}

	// Even while the compatibility flag is deliberately enabled, a legacy
	// token cannot perform the one-way provider detachment.
	migration := Setup(RouterConfig{DB: db, JWTSecret: secret, LegacyAuthEnabled: true, FirstPartyAuthEnabled: true})
	detach := httptest.NewRequest(http.MethodPost, "/api/v1/auth/clerk-detachment", nil)
	detach.Header.Set("Authorization", "Bearer "+token)
	detachResponse := httptest.NewRecorder()
	migration.ServeHTTP(detachResponse, detach)
	if detachResponse.Code != http.StatusUnauthorized || !strings.Contains(detachResponse.Body.String(), "first_party_session_required") {
		t.Fatalf("legacy token detached Clerk = %d: %s", detachResponse.Code, detachResponse.Body.String())
	}
}

func TestClerkDetachmentAllowsDeletionWithoutClerkConfiguration(t *testing.T) {
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	db, err := database.New(databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if err := db.RunMigrations("../../migrations"); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	clerkID := "user_" + uuid.NewString()
	var userID string
	if err := db.QueryRowContext(ctx, `
		INSERT INTO users (email, password_hash, name, clerk_id)
		VALUES ($1, '', 'HTTP detach test', $2) RETURNING id`, uuid.NewString()+"@example.com", clerkID).Scan(&userID); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `
		INSERT INTO auth_identities (user_id, provider, subject) VALUES ($1, 'clerk', $2);
		INSERT INTO auth_passkey_credentials (credential_id, user_id, credential) VALUES ($3, $1, '{}')`, userID, clerkID, []byte("http-detach-"+uuid.NewString())); err != nil {
		t.Fatal(err)
	}
	rotation, err := db.BeginRecoveryCodeRotation(ctx, userID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.ConfirmRecoveryCodeRotation(ctx, userID, rotation.ID); err != nil {
		t.Fatal(err)
	}
	pair, err := db.CreateFirstPartySession(ctx, userID, "ios", "No-Clerk deletion test")
	if err != nil {
		t.Fatal(err)
	}

	engine := Setup(RouterConfig{DB: db, FirstPartyAuthEnabled: true, ClerkAccountDeletionEnabled: false})
	authRequest := func(method, path, body string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, path, strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+pair.AccessToken)
		if body != "" {
			req.Header.Set("Content-Type", "application/json")
		}
		response := httptest.NewRecorder()
		engine.ServeHTTP(response, req)
		return response
	}
	status := authRequest(http.MethodGet, "/api/v1/auth/clerk-detachment", "")
	if status.Code != http.StatusOK || !strings.Contains(status.Body.String(), `"ready":true`) {
		t.Fatalf("detachment readiness = %d: %s", status.Code, status.Body.String())
	}
	detached := authRequest(http.MethodPost, "/api/v1/auth/clerk-detachment", "")
	if detached.Code != http.StatusOK || !strings.Contains(detached.Body.String(), `"linked":false`) {
		t.Fatalf("detach = %d: %s", detached.Code, detached.Body.String())
	}
	deleted := authRequest(http.MethodDelete, "/api/v1/account", `{"confirmation":"DELETE"}`)
	if deleted.Code != http.StatusAccepted {
		t.Fatalf("delete without Clerk configuration = %d: %s", deleted.Code, deleted.Body.String())
	}

	var requestID string
	var providerID *string
	var providerDeletedAt *time.Time
	if err := db.QueryRowxContext(ctx, `
		SELECT id, clerk_user_id, clerk_deleted_at FROM account_deletion_requests WHERE app_user_id = $1`, userID).
		Scan(&requestID, &providerID, &providerDeletedAt); err != nil {
		t.Fatal(err)
	}
	if providerID != nil || providerDeletedAt == nil {
		t.Fatalf("native deletion provider state = id %#v deleted_at %#v", providerID, providerDeletedAt)
	}
	t.Cleanup(func() {
		_, _ = db.ExecContext(context.Background(), `DELETE FROM background_jobs WHERE resource_id = $1`, requestID)
		_, _ = db.ExecContext(context.Background(), `DELETE FROM account_deletion_requests WHERE id = $1`, requestID)
	})
}
