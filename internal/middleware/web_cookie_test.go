package middleware

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestWebCookieAuthRequiresCSRFOnMutations(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(WebCookieAuth([]string{"https://media.example.com"}))
	r.POST("/api/v1/transcripts", func(c *gin.Context) {
		if c.GetHeader("Authorization") != "Bearer mta_at_example" {
			t.Errorf("cookie access credential was not promoted to bearer")
		}
		c.Status(http.StatusNoContent)
	})

	tests := []struct {
		name, origin, csrf, apiKey string
		want                       int
	}{
		{name: "valid", origin: "https://media.example.com", csrf: "secret", want: http.StatusNoContent},
		{name: "missing header", origin: "https://media.example.com", want: http.StatusForbidden},
		{name: "sibling origin", origin: "https://other.example.com", csrf: "secret", want: http.StatusForbidden},
		{name: "missing origin", csrf: "secret", want: http.StatusForbidden},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/api/v1/transcripts", strings.NewReader("{}"))
			req.AddCookie(&http.Cookie{Name: WebAccessCookie, Value: "mta_at_example"})
			req.AddCookie(&http.Cookie{Name: WebCSRFCookie, Value: "secret"})
			if tt.origin != "" {
				req.Header.Set("Origin", tt.origin)
			}
			if tt.csrf != "" {
				req.Header.Set(WebCSRFHeader, tt.csrf)
			}
			response := httptest.NewRecorder()
			r.ServeHTTP(response, req)
			if response.Code != tt.want {
				t.Fatalf("got %d, want %d", response.Code, tt.want)
			}
		})
	}
}

func TestWebCookieAuthDoesNotReplaceExplicitCredentials(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(WebCookieAuth([]string{"https://media.example.com"}))
	r.POST("/api/v1/transcripts", func(c *gin.Context) {
		if c.GetHeader("X-API-Key") != "agent-key" {
			t.Error("API key was removed")
		}
		if c.GetHeader("Authorization") != "" {
			t.Error("cookie overrode API key")
		}
		c.Status(http.StatusNoContent)
	})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/transcripts", nil)
	req.AddCookie(&http.Cookie{Name: WebAccessCookie, Value: "mta_at_example"})
	req.Header.Set("X-API-Key", "agent-key")
	response := httptest.NewRecorder()
	r.ServeHTTP(response, req)
	if response.Code != http.StatusNoContent {
		t.Fatalf("got %d", response.Code)
	}
}
