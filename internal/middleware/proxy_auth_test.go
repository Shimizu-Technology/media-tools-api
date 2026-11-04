package middleware

import (
	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
	"net/http/httptest"
	"testing"
	"time"
)

func TestVerifiedProxyClientIPAndFailSafeDefaults(t *testing.T) {
	const secret = "synthetic-proxy-signature-secret"
	sign := func(method jwt.SigningMethod, issuer string, expiry *jwt.NumericDate) string {
		token, err := jwt.NewWithClaims(method, jwt.RegisteredClaims{Issuer: issuer, ExpiresAt: expiry}).SignedString([]byte(secret))
		if err != nil {
			t.Fatal(err)
		}
		return token
	}
	valid := sign(jwt.SigningMethodHS256, "netlify", jwt.NewNumericDate(time.Now().Add(time.Minute)))
	for _, tc := range []struct {
		name, token, key, cf, nf, want string
		render                         bool
	}{
		{name: "unconfigured spoof", token: valid, cf: "198.51.100.7", nf: "203.0.113.8", want: "10.0.0.2"},
		{name: "signed Netlify", token: valid, key: secret, nf: "203.0.113.8", cf: "198.51.100.7", render: true, want: "203.0.113.8"},
		{name: "invalid signature", token: valid, key: "different-test-secret", nf: "203.0.113.8", want: "10.0.0.2"},
		{name: "wrong algorithm", token: sign(jwt.SigningMethodHS384, "netlify", jwt.NewNumericDate(time.Now().Add(time.Minute))), key: secret, nf: "203.0.113.8", want: "10.0.0.2"},
		{name: "wrong issuer", token: sign(jwt.SigningMethodHS256, "attacker", jwt.NewNumericDate(time.Now().Add(time.Minute))), key: secret, nf: "203.0.113.8", want: "10.0.0.2"},
		{name: "expired", token: sign(jwt.SigningMethodHS256, "netlify", jwt.NewNumericDate(time.Now().Add(-time.Minute))), key: secret, nf: "203.0.113.8", want: "10.0.0.2"},
		{name: "no expiry", token: sign(jwt.SigningMethodHS256, "netlify", nil), key: secret, nf: "203.0.113.8", want: "10.0.0.2"},
		{name: "malformed IP", token: valid, key: secret, nf: "203.0.113.8, 1.2.3.4", want: "10.0.0.2"},
		{name: "public Render", render: true, cf: "198.51.100.7", nf: "spoofed", want: "198.51.100.7"},
		{name: "Render malformed", render: true, cf: "not-an-ip", want: "10.0.0.2"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			engine := gin.New()
			engine.Use(ClientIP(nil, ClientIPOptions{RenderPublicEdge: tc.render, NetlifySignatureSecret: tc.key}))
			engine.GET("/", func(c *gin.Context) {
				if got := AuthClientIP(c); got != tc.want {
					t.Fatalf("IP=%s want=%s", got, tc.want)
				}
			})
			req := httptest.NewRequest("GET", "/", nil)
			req.RemoteAddr = "10.0.0.2:1234"
			req.Header.Set("X-Forwarded-For", "1.2.3.4")
			req.Header.Set("CF-Connecting-IP", tc.cf)
			req.Header.Set("X-Nf-Client-Connection-Ip", tc.nf)
			req.Header.Set("X-Nf-Sign", tc.token)
			engine.ServeHTTP(httptest.NewRecorder(), req)
		})
	}
}

func TestUnverifiedSharedProxyNeverExhaustsGlobalAuthBucket(t *testing.T) {
	limiter := NewRateLimiter("", "", 100, 100)
	engine := gin.New()
	engine.Use(ClientIP(nil))
	engine.POST("/", limiter.RateLimitUnauthenticated("recovery", 1), func(c *gin.Context) { c.Status(204) })
	for i := 0; i < 5; i++ {
		req := httptest.NewRequest("POST", "/", nil)
		req.RemoteAddr = "10.0.0.2:1234"
		rec := httptest.NewRecorder()
		engine.ServeHTTP(rec, req)
		if rec.Code != 204 {
			t.Fatal("unverified shared proxy became global bucket")
		}
	}
}
