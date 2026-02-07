package handlers

import (
	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
)

// isOwnerRequest returns true when the authenticated API key is configured
// as the owner override (used to bypass rate limits / queue caps).
func (h *Handler) isOwnerRequest(c *gin.Context) bool {
	apiKey := middleware.GetAPIKey(c)
	return middleware.IsOwnerAPIKey(apiKey, h.OwnerAPIKeyID, h.OwnerAPIKeyPrefix)
}
