package handlers

import (
	"errors"
	"log"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

func firstPartyAccount(c *gin.Context) *models.User {
	user := middleware.GetUser(c)
	if user == nil || !strings.HasPrefix(middleware.AuthSessionBinding(c), "first-party:") {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{
			Error:   "first_party_session_required",
			Message: "A signed-in first-party device session is required.",
			Code:    http.StatusUnauthorized,
		})
		return nil
	}
	return user
}

// ClerkDetachmentStatus reports whether a migrated account can safely stop
// using Clerk without exposing credentials or provider identifiers.
func (h *Handler) ClerkDetachmentStatus(c *gin.Context) {
	user := firstPartyAccount(c)
	if user == nil {
		return
	}
	status, err := h.DB.GetClerkDetachmentReadiness(c.Request.Context(), user.ID, h.Passwords != nil)
	if err != nil {
		log.Printf("check Clerk detachment for user %s: %v", user.ID, err)
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not check account security readiness.", Code: http.StatusServiceUnavailable})
		return
	}
	c.Header("Cache-Control", "no-store")
	c.JSON(http.StatusOK, status)
}

// DetachClerk removes the legacy provider link only after a password or
// passkey and at least one unused recovery code are present. It does not revoke device
// sessions or delete account data.
func (h *Handler) DetachClerk(c *gin.Context) {
	user := firstPartyAccount(c)
	if user == nil {
		return
	}
	status, err := h.DB.DetachClerkIdentity(c.Request.Context(), user.ID, h.Passwords != nil)
	if errors.Is(err, database.ErrClerkDetachmentNotReady) {
		c.Header("Cache-Control", "no-store")
		c.JSON(http.StatusConflict, gin.H{
			"error": "first_party_recovery_required", "message": "Add a password or passkey and save recovery codes before disconnecting Clerk.", "code": http.StatusConflict,
			"readiness": status,
		})
		return
	}
	if err != nil {
		log.Printf("detach Clerk for user %s: %v", user.ID, err)
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not disconnect Clerk.", Code: http.StatusServiceUnavailable})
		return
	}
	c.Header("Cache-Control", "no-store")
	c.JSON(http.StatusOK, status)
}
