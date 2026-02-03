// apikeys.go handles API key management endpoints.
package handlers

import (
	"crypto/rand"
	"encoding/hex"
	"log"
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

// CreateAPIKey generates a new API key.
// POST /api/v1/keys
//
// Security: This endpoint requires the X-Admin-Key header in production.
// In development (when ADMIN_API_KEY is not set), the endpoint is open for bootstrapping.
//
// Request body:
//
//	{"name": "My App", "rate_limit": 200}
//
// Response includes the raw key — SAVE IT! It's only shown once.
func (h *Handler) CreateAPIKey(c *gin.Context) {
	// Security: Require admin key if one is configured
	if h.AdminAPIKey != "" {
		providedKey := c.GetHeader("X-Admin-Key")
		if providedKey == "" {
			c.JSON(http.StatusUnauthorized, models.ErrorResponse{
				Error:   "unauthorized",
				Message: "X-Admin-Key header is required to create API keys",
				Code:    http.StatusUnauthorized,
			})
			return
		}
		if providedKey != h.AdminAPIKey {
			c.JSON(http.StatusForbidden, models.ErrorResponse{
				Error:   "forbidden",
				Message: "Invalid admin key",
				Code:    http.StatusForbidden,
			})
			return
		}
	}

	var req models.CreateAPIKeyRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_request",
			Message: "name is required",
			Code:    http.StatusBadRequest,
		})
		return
	}

	// Generate a secure random API key
	// Go Pattern: crypto/rand is the cryptographically secure random source.
	// NEVER use math/rand for security-sensitive things like API keys!
	rawKey, err := generateAPIKey()
	if err != nil {
		log.Printf("❌ Failed to generate API key: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "generation_error",
			Message: "Failed to generate API key",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	// Set default rate limit if not specified
	rateLimit := req.RateLimit
	if rateLimit <= 0 {
		rateLimit = 100 // Default: 100 requests/hour
	}

	// Create the key record with the HASH (never store the raw key)
	key := &models.APIKey{
		KeyHash:   middleware.HashAPIKey(rawKey),
		KeyPrefix: rawKey[:8] + "...", // Show first 8 chars for identification
		Name:      req.Name,
		Active:    true,
		RateLimit: rateLimit,
	}

	if err := h.DB.CreateAPIKey(c.Request.Context(), key); err != nil {
		log.Printf("❌ Failed to create API key: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to create API key",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	// Return the key WITH the raw value — this is the ONLY time it's shown
	c.JSON(http.StatusCreated, models.CreateAPIKeyResponse{
		APIKey: *key,
		RawKey: rawKey,
	})
}

// ListAPIKeys returns all API keys (without the raw key values).
// GET /api/v1/keys
func (h *Handler) ListAPIKeys(c *gin.Context) {
	keys, err := h.DB.ListAPIKeys(c.Request.Context())
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to list API keys",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	if keys == nil {
		keys = []models.APIKey{}
	}

	c.JSON(http.StatusOK, keys)
}

// RevokeAPIKey deactivates an API key.
// DELETE /api/v1/keys/:id
func (h *Handler) RevokeAPIKey(c *gin.Context) {
	id := c.Param("id")

	if err := h.DB.RevokeAPIKey(c.Request.Context(), id); err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error:   "not_found",
			Message: "API key not found",
			Code:    http.StatusNotFound,
		})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "API key revoked"})
}

// generateAPIKey creates a cryptographically secure random API key.
// Format: "mta_" prefix + 32 random hex characters = 36 chars total.
// The prefix makes it easy to identify keys from this service.
func generateAPIKey() (string, error) {
	// Generate 16 random bytes (= 32 hex characters)
	bytes := make([]byte, 16)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	return "mta_" + hex.EncodeToString(bytes), nil
}
