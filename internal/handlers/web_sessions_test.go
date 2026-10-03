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
	h := NewWebSessionHandler(nil, nil, true, nil)
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

func TestWebSessionMutationsRejectInvalidCSRF(t *testing.T) {
	gin.SetMode(gin.TestMode)
	h := NewWebSessionHandler(nil, nil, true, []string{"https://media.example.com"})
	for _, handler := range []struct {
		name string
		call func(*gin.Context)
	}{
		{"prepare", h.Prepare},
		{"refresh", h.Refresh},
		{"logout", h.Logout},
		{"bootstrap", h.Bootstrap},
		{"passkey-finish", h.FinishPasskeyLogin},
		{"password-finish", h.FinishPasswordLogin},
		{"recovery-finish", h.FinishRecoveryCodeLogin},
	} {
		t.Run(handler.name, func(t *testing.T) {
			response := httptest.NewRecorder()
			c, _ := gin.CreateTestContext(response)
			c.Request = httptest.NewRequest(http.MethodPost, "/api/v1/auth/web/session/"+handler.name, nil)
			c.Request.Header.Set("Origin", "https://media.example.com")
			c.Request.Header.Set(middleware.WebCSRFHeader, "wrong")
			c.Request.AddCookie(&http.Cookie{Name: middleware.WebCSRFCookie, Value: "expected"})
			handler.call(c)
			if response.Code != http.StatusForbidden {
				t.Fatalf("status = %d, want 403", response.Code)
			}
		})
	}
}

func TestPrepareWebBootstrapSetsOnlyHostCookies(t *testing.T) {
	gin.SetMode(gin.TestMode)
	h := NewWebSessionHandler(nil, nil, true, []string{"https://media.example.com"})
	response := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(response)
	c.Request = httptest.NewRequest(http.MethodPost, "/api/v1/auth/web/session/bootstrap/prepare", nil)
	c.Request.Header.Set("Origin", "https://media.example.com")
	h.PrepareBootstrap(c)
	c.Writer.WriteHeaderNow()
	if response.Code != http.StatusNoContent {
		t.Fatalf("prepare bootstrap = %d: %s", response.Code, response.Body.String())
	}
	cookies := response.Result().Cookies()
	var pending, csrf *http.Cookie
	for _, cookie := range cookies {
		if cookie.Domain != "" || !cookie.Secure || cookie.SameSite != http.SameSiteStrictMode {
			t.Errorf("unsafe bootstrap cookie: %+v", cookie)
		}
		if cookie.Name == middleware.WebPendingCookie {
			pending = cookie
		}
		if cookie.Name == middleware.WebCSRFCookie {
			csrf = cookie
		}
	}
	if pending == nil || !pending.HttpOnly || !database.ValidFirstPartyRefreshToken(pending.Value) {
		t.Fatalf("missing safe pending successor: %+v", pending)
	}
	if csrf == nil || csrf.HttpOnly || !strings.HasPrefix(csrf.Value, "mta_csrf_") {
		t.Fatalf("missing readable CSRF cookie: %+v", csrf)
	}
}

func TestSignedOutWebAuthBeginsRejectWrongOrigin(t *testing.T) {
	gin.SetMode(gin.TestMode)
	h := NewWebSessionHandler(nil, nil, true, []string{"https://media.example.com"})
	for _, call := range []func(*gin.Context){h.PrepareBootstrap, h.BeginPasskeyLogin, h.PreparePasswordLogin, h.PrepareRecoveryCodeLogin} {
		response := httptest.NewRecorder()
		c, _ := gin.CreateTestContext(response)
		c.Request = httptest.NewRequest(http.MethodPost, "/api/v1/auth/web/session/start", nil)
		c.Request.Header.Set("Origin", "https://attacker.example.com")
		call(c)
		if response.Code != http.StatusForbidden {
			t.Fatalf("wrong origin status = %d", response.Code)
		}
	}
}

func TestWebSessionRefreshRequiresPreparation(t *testing.T) {
	gin.SetMode(gin.TestMode)
	h := NewWebSessionHandler(nil, nil, true, []string{"https://media.example.com"})
	response := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(response)
	c.Request = httptest.NewRequest(http.MethodPost, "/api/v1/auth/web/session/refresh", nil)
	c.Request.Header.Set("Origin", "https://media.example.com")
	c.Request.Header.Set(middleware.WebCSRFHeader, "matching")
	c.Request.AddCookie(&http.Cookie{Name: middleware.WebCSRFCookie, Value: "matching"})
	c.Request.AddCookie(&http.Cookie{Name: middleware.WebRefreshCookie, Value: "mta_rt_existing"})
	h.Refresh(c)
	if response.Code != http.StatusBadRequest || !strings.Contains(response.Body.String(), "refresh_not_prepared") {
		t.Fatalf("unprepared refresh = %d %s", response.Code, response.Body.String())
	}
}

func TestWebSessionClearPendingCookie(t *testing.T) {
	gin.SetMode(gin.TestMode)
	h := NewWebSessionHandler(nil, nil, true, nil)
	response := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(response)
	h.clearPending(c)
	cookies := response.Result().Cookies()
	if len(cookies) != 1 {
		t.Fatalf("cleared %d cookies, want pending cookie only", len(cookies))
	}
	cookie := cookies[0]
	if cookie.Name != middleware.WebPendingCookie || cookie.Path != "/api/v1/auth/web/session" {
		t.Fatalf("cleared wrong cookie: %+v", cookie)
	}
	if cookie.MaxAge != -1 || cookie.Value != "" || !cookie.Secure || !cookie.HttpOnly || cookie.SameSite != http.SameSiteStrictMode {
		t.Fatalf("pending cookie was not cleared safely: %+v", cookie)
	}
}

func TestWebSessionLogoutClearsAllCookies(t *testing.T) {
	gin.SetMode(gin.TestMode)
	h := NewWebSessionHandler(nil, nil, true, []string{"https://media.example.com"})
	response := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(response)
	c.Request = httptest.NewRequest(http.MethodPost, "/api/v1/auth/web/session/logout", nil)
	c.Request.Header.Set("Origin", "https://media.example.com")
	c.Request.Header.Set(middleware.WebCSRFHeader, "matching")
	c.Request.AddCookie(&http.Cookie{Name: middleware.WebCSRFCookie, Value: "matching"})
	h.Logout(c)
	c.Writer.WriteHeaderNow()
	if response.Code != http.StatusNoContent {
		t.Fatalf("logout status = %d, want 204", response.Code)
	}
	cookies := response.Result().Cookies()
	if len(cookies) != 10 {
		t.Fatalf("cleared %d cookies, want 10", len(cookies))
	}
	for _, cookie := range cookies {
		if cookie.MaxAge != -1 || cookie.Value != "" {
			t.Errorf("cookie %s was not cleared: %+v", cookie.Name, cookie)
		}
	}
}
