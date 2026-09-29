package router

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
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
