package middleware

import (
	"github.com/gin-gonic/gin"
	"net/http/httptest"
	"testing"
)

func TestClientIPTrustBoundary(t *testing.T) {
	for _, tc := range []struct {
		name, peer, forwarded, want string
		trusted                     []string
	}{
		{"direct spoof", "203.0.113.9:123", "1.2.3.4", "203.0.113.9", nil},
		{"untrusted hop", "10.0.0.2:123", "1.2.3.4, 198.51.100.2", "198.51.100.2", []string{"10.0.0.0/24"}},
		{"two proxies", "10.0.0.2:123", "1.2.3.4, 203.0.113.9, 198.51.100.2", "203.0.113.9", []string{"10.0.0.0/24", "198.51.100.0/24"}},
		{"malformed", "10.0.0.2:123", "203.0.113.9, nope", "10.0.0.2", []string{"10.0.0.0/24"}},
		{"ipv6", "[2001:db8::1]:123", "1.2.3.4", "2001:db8::1", nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			engine := gin.New()
			engine.Use(ClientIP(tc.trusted))
			engine.GET("/", func(c *gin.Context) {
				if got := AuthClientIP(c); got != tc.want {
					t.Fatalf("IP=%s want=%s", got, tc.want)
				}
			})
			req := httptest.NewRequest("GET", "/", nil)
			req.RemoteAddr = tc.peer
			req.Header.Set("X-Forwarded-For", tc.forwarded)
			req.Header.Set("X-Nf-Client-Connection-Ip", "9.9.9.9")
			engine.ServeHTTP(httptest.NewRecorder(), req)
		})
	}
}

func TestClientIPMultipleForwardedHeadersUseNearestAppendedHop(t *testing.T) {
	engine := gin.New()
	engine.Use(ClientIP([]string{"10.0.0.0/24"}))
	engine.GET("/", func(c *gin.Context) {
		if AuthClientIP(c) != "203.0.113.9" {
			t.Fatal("spoofed first header bypassed the nearest appended hop")
		}
	})
	req := httptest.NewRequest("GET", "/", nil)
	req.RemoteAddr = "10.0.0.2:123"
	req.Header.Add("X-Forwarded-For", "1.2.3.4")
	req.Header.Add("X-Forwarded-For", "203.0.113.9")
	engine.ServeHTTP(httptest.NewRecorder(), req)
}
