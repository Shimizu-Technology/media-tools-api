package handlers

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

func TestWebBootstrapRecoversLostResponseWithoutAnotherSession(t *testing.T) {
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
	clerkID := "user_" + uuid.NewString()
	user := &models.User{Email: uuid.NewString() + "@example.com", Name: "Web Bootstrap", ClerkID: &clerkID}
	if err := db.QueryRowContext(ctx, `INSERT INTO users (email, password_hash, name, clerk_id) VALUES ($1, '', $2, $3) RETURNING id`, user.Email, user.Name, clerkID).Scan(&user.ID); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, user.ID) })

	h := NewWebSessionHandler(db, nil, true, []string{"https://media.example.com"})
	prepareResponse := httptest.NewRecorder()
	prepareContext, _ := gin.CreateTestContext(prepareResponse)
	prepareContext.Request = httptest.NewRequest(http.MethodPost, "/api/v1/auth/web/session/bootstrap/prepare", nil)
	prepareContext.Request.Header.Set("Origin", "https://media.example.com")
	h.PrepareBootstrap(prepareContext)
	prepareContext.Writer.WriteHeaderNow()
	pending := findResponseCookie(prepareResponse.Result().Cookies(), middleware.WebPendingCookie)
	csrf := findResponseCookie(prepareResponse.Result().Cookies(), middleware.WebCSRFCookie)
	if prepareResponse.Code != http.StatusNoContent || pending == nil || csrf == nil {
		t.Fatalf("prepare bootstrap = %d, cookies=%#v", prepareResponse.Code, prepareResponse.Result().Cookies())
	}

	commit := func() *httptest.ResponseRecorder {
		response := httptest.NewRecorder()
		c, _ := gin.CreateTestContext(response)
		c.Request = httptest.NewRequest(http.MethodPost, "/api/v1/auth/web/session/bootstrap", nil)
		c.Request.Header.Set("Origin", "https://media.example.com")
		c.Request.Header.Set(middleware.WebCSRFHeader, csrf.Value)
		c.Request.AddCookie(pending)
		c.Request.AddCookie(csrf)
		c.Set("user", user)
		h.Bootstrap(c)
		return response
	}
	first := commit()
	if first.Code != http.StatusCreated || bytes.Contains(first.Body.Bytes(), []byte("access_token")) || bytes.Contains(first.Body.Bytes(), []byte("refresh_token")) {
		t.Fatalf("first bootstrap = %d: %s", first.Code, first.Body.String())
	}
	// A browser that never receives the first response still has the prepared
	// cookie jar. Repeating the exact commit recovers the same session.
	recovered := commit()
	if recovered.Code != http.StatusCreated || bytes.Contains(recovered.Body.Bytes(), []byte("access_token")) || bytes.Contains(recovered.Body.Bytes(), []byte("refresh_token")) {
		t.Fatalf("recovered bootstrap = %d: %s", recovered.Code, recovered.Body.String())
	}
	recoveredRefresh := findResponseCookie(recovered.Result().Cookies(), middleware.WebRefreshCookie)
	if recoveredRefresh == nil || recoveredRefresh.Value != pending.Value {
		t.Fatalf("recovered bootstrap changed successor: %#v", recovered.Result().Cookies())
	}
	var sessions int
	if err := db.GetContext(ctx, &sessions, `SELECT COUNT(*) FROM auth_sessions WHERE user_id = $1 AND client_type = 'web' AND device_name = 'Browser'`, user.ID); err != nil || sessions != 1 {
		t.Fatalf("bootstrap session count = %d, %v", sessions, err)
	}
}

func findResponseCookie(cookies []*http.Cookie, name string) *http.Cookie {
	for _, cookie := range cookies {
		if cookie.Name == name && cookie.MaxAge >= 0 {
			return cookie
		}
	}
	return nil
}
