// Package middleware provides HTTP middleware for the API.
//
// Go Pattern: Middleware in Go is a function that wraps an HTTP handler.
// In Gin, middleware is a gin.HandlerFunc that calls c.Next() to continue
// the chain, or c.Abort() to stop processing. This is similar to Express.js
// middleware, but with explicit control flow.
package middleware

import (
	"crypto/sha256"
	"fmt"
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

// contextKey is a custom type for context keys to avoid collisions.
// Go Pattern: Use unexported types for context keys so other packages
// can't accidentally overwrite your values.
type contextKey string

const apiKeyContextKey contextKey = "api_key"

// APIKeyAuth returns middleware that validates the X-API-Key header.
//
// How it works:
// 1. Read the X-API-Key header
// 2. Hash it (we never store raw keys)
// 3. Look up the hash in the database
// 4. If valid, store the key info in the request context
// 5. If invalid, return 401 Unauthorized
func APIKeyAuth(db *database.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		// Read the API key from the header
		rawKey := c.GetHeader("X-API-Key")
		if rawKey == "" {
			c.JSON(http.StatusUnauthorized, models.ErrorResponse{
				Error:   "unauthorized",
				Message: "Missing X-API-Key header. Create an API key via POST /api/v1/keys",
				Code:    http.StatusUnauthorized,
			})
			c.Abort() // Stop the middleware chain — don't call the handler
			return
		}

		// Hash the key and look it up
		keyHash := HashAPIKey(rawKey)
		apiKey, err := db.GetAPIKeyByHash(c.Request.Context(), keyHash)
		if err != nil {
			c.JSON(http.StatusUnauthorized, models.ErrorResponse{
				Error:   "unauthorized",
				Message: "Invalid or revoked API key",
				Code:    http.StatusUnauthorized,
			})
			c.Abort()
			return
		}

		// Store the API key info in Gin's context for later use
		// Go Pattern: Gin uses its own context (different from context.Context).
		// c.Set() stores values that handlers can retrieve with c.Get().
		c.Set(string(apiKeyContextKey), apiKey)

		// Update last_used_at (fire and forget — don't block the request)
		// Go Pattern: Using a goroutine for non-critical background work.
		go db.UpdateAPIKeyLastUsed(c.Request.Context(), apiKey.ID)

		// Continue to the next handler
		c.Next()
	}
}

// GetAPIKey retrieves the authenticated API key from the request context.
// Call this in your handlers after the auth middleware has run.
func GetAPIKey(c *gin.Context) *models.APIKey {
	val, exists := c.Get(string(apiKeyContextKey))
	if !exists {
		return nil
	}
	// Go Pattern: Type assertion — converting interface{} to a concrete type.
	// The comma-ok idiom (val, ok := ...) is safe — it won't panic if wrong type.
	key, ok := val.(*models.APIKey)
	if !ok {
		return nil
	}
	return key
}

// HashAPIKey creates a SHA-256 hash of an API key.
// We store hashes, not raw keys — same principle as password hashing.
func HashAPIKey(key string) string {
	hash := sha256.Sum256([]byte(key))
	return fmt.Sprintf("%x", hash)
}
