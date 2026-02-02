// ratelimit.go implements per-API-key rate limiting using a token bucket algorithm.
//
// How token bucket works:
// - Each API key gets a "bucket" with N tokens (= rate_limit from the database)
// - Each request consumes 1 token
// - Tokens refill at a steady rate (rate_limit tokens per hour)
// - If the bucket is empty, the request is rejected with 429 Too Many Requests
//
// This is more sophisticated than a simple counter because it smooths out
// burst traffic naturally.
package middleware

import (
	"fmt"
	"net/http"
	"sync"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

// RateLimiter tracks request rates per API key.
type RateLimiter struct {
	// Go Pattern: sync.RWMutex allows multiple concurrent readers but
	// exclusive writers. This is more efficient than sync.Mutex when
	// reads vastly outnumber writes (which is true for rate limiting).
	mu      sync.RWMutex
	buckets map[string]*bucket
}

// bucket tracks the token state for a single API key.
type bucket struct {
	tokens     float64
	maxTokens  float64
	refillRate float64 // tokens per second
	lastRefill time.Time
}

// NewRateLimiter creates a new rate limiter.
func NewRateLimiter() *RateLimiter {
	rl := &RateLimiter{
		buckets: make(map[string]*bucket),
	}

	// Start background cleanup goroutine
	go rl.cleanup()

	return rl
}

// RateLimit returns Gin middleware that enforces per-key rate limits.
func (rl *RateLimiter) RateLimit() gin.HandlerFunc {
	return func(c *gin.Context) {
		// Get the API key from context (set by auth middleware)
		apiKey := GetAPIKey(c)
		if apiKey == nil {
			// No API key = no rate limiting (auth middleware handles rejection)
			c.Next()
			return
		}

		// Check rate limit
		allowed := rl.allow(apiKey.ID, apiKey.RateLimit)
		if !allowed {
			c.JSON(http.StatusTooManyRequests, models.ErrorResponse{
				Error:   "rate_limit_exceeded",
				Message: "Rate limit exceeded. Try again later.",
				Code:    http.StatusTooManyRequests,
			})
			c.Abort()
			return
		}

		// Add rate limit headers so clients know their limits
		// Go Pattern: These headers follow the standard draft RFC for rate limiting.
		b := rl.getBucket(apiKey.ID)
		if b != nil {
			c.Header("X-RateLimit-Limit", formatFloat(b.maxTokens))
			c.Header("X-RateLimit-Remaining", formatFloat(b.tokens))
		}

		c.Next()
	}
}

// allow checks if a request should be allowed, consuming a token if so.
func (rl *RateLimiter) allow(keyID string, rateLimit int) bool {
	rl.mu.Lock()
	defer rl.mu.Unlock()

	b, exists := rl.buckets[keyID]
	if !exists {
		// Create a new bucket for this key
		b = &bucket{
			tokens:     float64(rateLimit),
			maxTokens:  float64(rateLimit),
			refillRate: float64(rateLimit) / 3600.0, // tokens per second (rate per hour)
			lastRefill: time.Now(),
		}
		rl.buckets[keyID] = b
	}

	// Refill tokens based on elapsed time
	now := time.Now()
	elapsed := now.Sub(b.lastRefill).Seconds()
	b.tokens += elapsed * b.refillRate
	if b.tokens > b.maxTokens {
		b.tokens = b.maxTokens
	}
	b.lastRefill = now

	// Check if we have a token available
	if b.tokens < 1.0 {
		return false
	}

	// Consume a token
	b.tokens--
	return true
}

// getBucket returns the bucket for a key (read-only, for headers).
func (rl *RateLimiter) getBucket(keyID string) *bucket {
	rl.mu.RLock()
	defer rl.mu.RUnlock()
	return rl.buckets[keyID]
}

// cleanup periodically removes stale buckets to prevent memory leaks.
func (rl *RateLimiter) cleanup() {
	// Go Pattern: time.Ticker sends values at regular intervals.
	// Always defer ticker.Stop() to release resources.
	ticker := time.NewTicker(10 * time.Minute)
	defer ticker.Stop()

	for range ticker.C {
		rl.mu.Lock()
		now := time.Now()
		for id, b := range rl.buckets {
			// Remove buckets that haven't been used in over an hour
			if now.Sub(b.lastRefill) > time.Hour {
				delete(rl.buckets, id)
			}
		}
		rl.mu.Unlock()
	}
}

// formatFloat converts a float to a string for headers.
func formatFloat(f float64) string {
	return fmt.Sprintf("%.0f", f)
}
