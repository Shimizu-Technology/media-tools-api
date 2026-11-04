package middleware

import (
	"context"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

const userContextKey = "user"
const firstPartySessionContextKey = "first_party_session_id"

// DualAuth returns middleware that accepts an API key and the explicitly
// enabled bearer-token providers.
// First-party device sessions and API keys are the supported credentials.
func DualAuth(db *database.DB, firstPartyEnabled bool) gin.HandlerFunc {
	acceptFirstParty := firstPartyEnabled
	return func(c *gin.Context) {
		// Try API key first
		rawKey := c.GetHeader("X-API-Key")
		if rawKey != "" {
			keyHash := HashAPIKey(rawKey)
			apiKey, err := db.GetAPIKeyByHash(c.Request.Context(), keyHash)
			if err == nil {
				c.Set(string(apiKeyContextKey), apiKey)
				// BUG FIX: Use context.Background() — goroutine outlives request
				go func() {
					ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
					defer cancel()
					db.UpdateAPIKeyLastUsed(ctx, apiKey.ID)
				}()
				c.Next()
				return
			}
		}

		// First-party device sessions and API keys are the supported credentials.
		authHeader := c.GetHeader("Authorization")
		if authHeader != "" && strings.HasPrefix(authHeader, "Bearer ") {
			tokenString := strings.TrimPrefix(authHeader, "Bearer ")
			if acceptFirstParty && strings.HasPrefix(tokenString, "mta_at_") {
				user, sessionID, err := db.GetUserByFirstPartyAccessToken(c.Request.Context(), tokenString)
				if err == nil {
					c.Set(userContextKey, user)
					c.Set(firstPartySessionContextKey, sessionID)
					c.Next()
					return
				}
				if err != database.ErrSessionInvalid {
					log.Printf("First-party credential lookup failed: %v", err)
					c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not verify session", Code: http.StatusServiceUnavailable})
					c.Abort()
					return
				}
				c.JSON(http.StatusUnauthorized, models.ErrorResponse{Error: "unauthorized", Message: "Invalid or expired session", Code: http.StatusUnauthorized})
				c.Abort()
				return
			}

		}

		// Neither auth method worked
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{
			Error:   "unauthorized",
			Message: "Provide a valid X-API-Key header or Authorization: Bearer <token>",
			Code:    http.StatusUnauthorized,
		})
		c.Abort()
	}
}

// GetUser retrieves the authenticated user from the request context.
func GetUser(c *gin.Context) *models.User {
	val, exists := c.Get(userContextKey)
	if !exists {
		return nil
	}
	user, ok := val.(*models.User)
	if !ok {
		return nil
	}
	return user
}

// AuthSessionBinding binds sensitive ceremonies to the requesting device.
// API keys have no device binding and cannot enroll passkeys.
func AuthSessionBinding(c *gin.Context) string {
	if id, ok := c.Get(firstPartySessionContextKey); ok {
		if sessionID, ok := id.(string); ok && sessionID != "" {
			return "first-party:" + sessionID
		}
	}

	return ""
}

// BearerOnlyAuth accepts the enabled bearer-token providers but not API keys.
// Used for user-scoped routes like /auth/me and /workspace where an API key
// should not grant access.
func BearerOnlyAuth(db *database.DB, firstPartyEnabled bool) gin.HandlerFunc {
	// Create DualAuth handler once at init, not per-request
	dualAuth := DualAuth(db, firstPartyEnabled)

	return func(c *gin.Context) {
		// Reject any request with API key, even if Authorization is also present
		if c.GetHeader("X-API-Key") != "" {
			c.JSON(http.StatusUnauthorized, models.ErrorResponse{
				Error:   "unauthorized",
				Message: "This endpoint requires a Bearer token, not an API key",
				Code:    http.StatusUnauthorized,
			})
			c.Abort()
			return
		}

		// Delegate to DualAuth for the enabled Bearer token providers.
		dualAuth(c)
	}
}
