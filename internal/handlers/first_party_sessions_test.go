package handlers

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

func bootstrapHandlerResponse(t *testing.T, handler *Handler, user *models.User, body string) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.POST("/bootstrap", func(c *gin.Context) {
		if user != nil {
			c.Set("user", user)
		}
		handler.BootstrapFirstPartySession(c)
	})
	request := httptest.NewRequest(http.MethodPost, "/bootstrap", strings.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	router.ServeHTTP(response, request)
	return response
}

func TestBootstrapFirstPartySessionRejectsNonNativeAndInvalidRequests(t *testing.T) {
	clerkID := "user_verified"
	user := &models.User{ID: uuid.NewString(), ClerkID: &clerkID}
	handler := &Handler{}

	if response := bootstrapHandlerResponse(t, handler, nil, `{}`); response.Code != http.StatusUnauthorized {
		t.Fatalf("missing verified user = %d: %s", response.Code, response.Body.String())
	}
	for name, body := range map[string]string{
		"missing successor":   `{"client_type":"ios"}`,
		"malformed successor": `{"client_type":"ios","next_refresh_token":"bad"}`,
		"raw web":             `{"client_type":"web","next_refresh_token":"mta_rt_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}`,
		"long device":         `{"client_type":"ios","device_name":"` + strings.Repeat("x", 81) + `","next_refresh_token":"mta_rt_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}`,
	} {
		t.Run(name, func(t *testing.T) {
			response := bootstrapHandlerResponse(t, handler, user, body)
			if response.Code != http.StatusBadRequest || strings.Contains(response.Body.String(), "access_token") || strings.Contains(response.Body.String(), "refresh_token") {
				t.Fatalf("response = %d: %s", response.Code, response.Body.String())
			}
		})
	}
}

func TestBootstrapFirstPartySessionRecoversLostResponse(t *testing.T) {
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
	clerkID := "user_" + uuid.NewString()
	var userID string
	if err := db.QueryRowContext(ctx, `
		INSERT INTO users (email, password_hash, name, clerk_id)
		VALUES ($1, '', 'Bootstrap Handler', $2) RETURNING id`,
		uuid.NewString()+"@example.com", clerkID).Scan(&userID); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, userID) })
	user := &models.User{ID: userID, ClerkID: &clerkID}
	next, err := database.RandomFirstPartyRefreshToken()
	if err != nil {
		t.Fatal(err)
	}
	body := `{"client_type":"ios","device_name":"iPhone","next_refresh_token":"` + next + `"}`
	handler := &Handler{DB: db}

	firstResponse := bootstrapHandlerResponse(t, handler, user, body)
	if firstResponse.Code != http.StatusCreated || firstResponse.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("first response = %d: %s", firstResponse.Code, firstResponse.Body.String())
	}
	var first database.AuthTokenPair
	if err := json.Unmarshal(firstResponse.Body.Bytes(), &first); err != nil {
		t.Fatal(err)
	}
	retryResponse := bootstrapHandlerResponse(t, handler, user, body)
	if retryResponse.Code != http.StatusCreated || retryResponse.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("retry response = %d: %s", retryResponse.Code, retryResponse.Body.String())
	}
	var retry database.AuthTokenPair
	if err := json.Unmarshal(retryResponse.Body.Bytes(), &retry); err != nil {
		t.Fatal(err)
	}
	if retry.SessionID != first.SessionID || retry.RefreshToken != next || retry.AccessToken == first.AccessToken {
		t.Fatalf("lost-response retry = first %#v retry %#v", first, retry)
	}
	var sessions, identities int
	if err := db.GetContext(ctx, &sessions, `SELECT COUNT(*) FROM auth_sessions WHERE user_id = $1`, userID); err != nil {
		t.Fatal(err)
	}
	if err := db.GetContext(ctx, &identities, `SELECT COUNT(*) FROM auth_identities WHERE user_id = $1 AND provider = 'clerk' AND subject = $2`, userID, clerkID); err != nil {
		t.Fatal(err)
	}
	if sessions != 1 || identities != 1 {
		t.Fatalf("bootstrap state sessions=%d identities=%d", sessions, identities)
	}

	// A refresh credential already owned by another session produces the same
	// generic invalid response and the failed transaction leaves no new tokens.
	existing, err := db.CreateFirstPartySession(ctx, userID, "ios", "Existing device")
	if err != nil {
		t.Fatal(err)
	}
	var accessBefore int
	if err := db.GetContext(ctx, &accessBefore, `SELECT COUNT(*) FROM auth_access_tokens a JOIN auth_sessions s ON s.id = a.session_id WHERE s.user_id = $1`, userID); err != nil {
		t.Fatal(err)
	}
	collisionBody := `{"client_type":"ios","next_refresh_token":"` + existing.RefreshToken + `"}`
	collision := bootstrapHandlerResponse(t, handler, user, collisionBody)
	if collision.Code != http.StatusBadRequest || strings.Contains(collision.Body.String(), "access_token") || strings.Contains(collision.Body.String(), "refresh_token") {
		t.Fatalf("collision response = %d: %s", collision.Code, collision.Body.String())
	}
	var accessAfter int
	if err := db.GetContext(ctx, &accessAfter, `SELECT COUNT(*) FROM auth_access_tokens a JOIN auth_sessions s ON s.id = a.session_id WHERE s.user_id = $1`, userID); err != nil || accessAfter != accessBefore {
		t.Fatalf("collision access count before=%d after=%d err=%v", accessBefore, accessAfter, err)
	}
}
