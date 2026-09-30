package middleware

import (
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

func TestRateLimiterSeparatesBrowserReadsFromMutations(t *testing.T) {
	gin.SetMode(gin.TestMode)
	limiter := NewRateLimiter("", "", 2, 5)
	router := gin.New()
	router.Use(func(c *gin.Context) {
		c.Set(userContextKey, &models.User{ID: "user-1"})
		c.Next()
	})
	router.Use(limiter.RateLimit())
	router.GET("/resource", func(c *gin.Context) { c.Status(http.StatusNoContent) })
	router.POST("/resource", func(c *gin.Context) { c.Status(http.StatusNoContent) })

	assertRateLimitResponse(t, router, http.MethodGet, http.StatusNoContent, "5", "4")
	assertRateLimitResponse(t, router, http.MethodPost, http.StatusNoContent, "2", "1")
	assertRateLimitResponse(t, router, http.MethodPost, http.StatusNoContent, "2", "0")
	assertRateLimitResponse(t, router, http.MethodPost, http.StatusTooManyRequests, "2", "0")
	// Exhausting the mutation bucket must not consume the independent read bucket.
	assertRateLimitResponse(t, router, http.MethodGet, http.StatusNoContent, "5", "3")
}

func TestRateLimiterKeepsAPIKeyTrafficInOneConfiguredBucket(t *testing.T) {
	gin.SetMode(gin.TestMode)
	limiter := NewRateLimiter("", "", 100, 10000)
	router := gin.New()
	router.Use(func(c *gin.Context) {
		c.Set(string(apiKeyContextKey), &models.APIKey{ID: "key-1", RateLimit: 2})
		c.Next()
	})
	router.Use(limiter.RateLimit())
	router.GET("/resource", func(c *gin.Context) { c.Status(http.StatusNoContent) })
	router.POST("/resource", func(c *gin.Context) { c.Status(http.StatusNoContent) })

	assertRateLimitResponse(t, router, http.MethodGet, http.StatusNoContent, "2", "1")
	assertRateLimitResponse(t, router, http.MethodPost, http.StatusNoContent, "2", "0")
	assertRateLimitResponse(t, router, http.MethodGet, http.StatusTooManyRequests, "2", "0")
}

func TestRateLimiterReturnsRetryAfterWhenBucketIsEmpty(t *testing.T) {
	gin.SetMode(gin.TestMode)
	limiter := NewRateLimiter("", "", 1, 1)
	router := gin.New()
	router.Use(func(c *gin.Context) {
		c.Set(userContextKey, &models.User{ID: "user-1"})
		c.Next()
	})
	router.Use(limiter.RateLimit())
	router.GET("/resource", func(c *gin.Context) { c.Status(http.StatusNoContent) })

	assertRateLimitResponse(t, router, http.MethodGet, http.StatusNoContent, "1", "0")
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/resource", nil)
	router.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusTooManyRequests)
	}
	retryAfter, err := strconv.Atoi(recorder.Header().Get("Retry-After"))
	if err != nil || retryAfter < 1 || retryAfter > 3600 {
		t.Fatalf("Retry-After = %q, want seconds between 1 and 3600", recorder.Header().Get("Retry-After"))
	}
}

func TestUnauthenticatedRateLimiterSeparatesAuthenticationScopes(t *testing.T) {
	gin.SetMode(gin.TestMode)
	limiter := NewRateLimiter("", "", 100, 100)
	router := gin.New()
	router.POST("/recovery", limiter.RateLimitUnauthenticated("recovery", 1), func(c *gin.Context) {
		c.Status(http.StatusNoContent)
	})
	router.POST("/passkey", limiter.RateLimitUnauthenticated("passkey", 2), func(c *gin.Context) {
		c.Status(http.StatusNoContent)
	})

	request := func(path string) int {
		recorder := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, path, nil)
		req.RemoteAddr = "192.0.2.10:54321"
		router.ServeHTTP(recorder, req)
		return recorder.Code
	}
	if got := request("/recovery"); got != http.StatusNoContent {
		t.Fatalf("first recovery status = %d", got)
	}
	if got := request("/recovery"); got != http.StatusTooManyRequests {
		t.Fatalf("second recovery status = %d", got)
	}
	if got := request("/passkey"); got != http.StatusNoContent {
		t.Fatalf("recovery bucket limited passkey status = %d", got)
	}
}

func assertRateLimitResponse(t *testing.T, handler http.Handler, method string, wantStatus int, wantLimit, wantRemaining string) {
	t.Helper()
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(method, "/resource", nil)
	handler.ServeHTTP(recorder, request)
	if recorder.Code != wantStatus {
		t.Fatalf("%s status = %d, want %d", method, recorder.Code, wantStatus)
	}
	if got := recorder.Header().Get("X-RateLimit-Limit"); got != wantLimit {
		t.Fatalf("%s X-RateLimit-Limit = %q, want %q", method, got, wantLimit)
	}
	if got := recorder.Header().Get("X-RateLimit-Remaining"); got != wantRemaining {
		t.Fatalf("%s X-RateLimit-Remaining = %q, want %q", method, got, wantRemaining)
	}
}
