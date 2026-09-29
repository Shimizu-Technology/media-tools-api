package handlers

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
)

func TestWebSessionCredentialsAreHostOnlyHttpOnlyAndSameSite(t *testing.T) {
	gin.SetMode(gin.TestMode)
	h := NewWebSessionHandler(nil, true, nil)
	response := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(response)
	h.setPair(c, &database.AuthTokenPair{
		AccessToken: "mta_at_secret", AccessExpiresAt: time.Now().Add(15 * time.Minute),
		RefreshToken: "mta_rt_secret",
	})
	result := response.Result()
	defer result.Body.Close()
	cookies := result.Cookies()
	if len(cookies) != 3 {
		t.Fatalf("got %d cookies, want access, refresh, and cleared pending", len(cookies))
	}
	for _, cookie := range cookies {
		if cookie.Domain != "" || !cookie.Secure || !cookie.HttpOnly || cookie.SameSite != http.SameSiteStrictMode {
			t.Errorf("unsafe cookie attributes for %s: %+v", cookie.Name, cookie)
		}
	}
	if cookies[0].Name != middleware.WebAccessCookie || cookies[0].Path != "/api/v1" {
		t.Errorf("access cookie has wrong name or path: %+v", cookies[0])
	}
	if cookies[1].Name != middleware.WebRefreshCookie || cookies[1].Path != "/api/v1/auth/web/session" {
		t.Errorf("refresh cookie has wrong name or path: %+v", cookies[1])
	}
	if strings.Contains(response.Body.String(), "mta_rt_secret") {
		t.Error("refresh credential leaked in body")
	}
}
