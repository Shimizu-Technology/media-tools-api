package handlers

import (
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

const accountDeletionConfirmation = "DELETE"

// DeleteAccount begins a durable, cross-system deletion. The database purge
// commits before the response; object storage and Clerk finish asynchronously.
// DELETE /api/v1/account
func (h *Handler) DeleteAccount(c *gin.Context) {
	if !h.ClerkAccountDeletionEnabled {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{
			Error:   "account_deletion_unavailable",
			Message: "Account deletion is temporarily unavailable. Please contact support.",
			Code:    http.StatusServiceUnavailable,
		})
		return
	}

	user := middleware.GetUser(c)
	if user == nil || user.ClerkID == nil || strings.TrimSpace(*user.ClerkID) == "" {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "clerk_account_required",
			Message: "This account is not managed by Clerk and cannot be deleted here.",
			Code:    http.StatusBadRequest,
		})
		return
	}

	var body models.DeleteAccountRequest
	if err := c.ShouldBindJSON(&body); err != nil || body.Confirmation != accountDeletionConfirmation {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "confirmation_required",
			Message: "Type DELETE to confirm permanent account deletion.",
			Code:    http.StatusBadRequest,
		})
		return
	}

	cleanupAfter := time.Now().UTC()
	if h.AudioStorage != nil && h.AudioStorage.IsConfigured() {
		cleanupAfter = cleanupAfter.Add(h.AudioStorage.PresignedURLExpiry() + 5*time.Minute)
	}
	request, err := h.DB.RequestAccountDeletion(
		c.Request.Context(), user.ID, *user.ClerkID, cleanupAfter,
	)
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "account_deletion_failed",
			Message: "Media Tools could not confirm account deletion. Please try again or contact support.",
			Code:    http.StatusInternalServerError,
		})
		return
	}
	if h.Worker != nil {
		h.Worker.Wake()
	}
	c.JSON(http.StatusAccepted, models.DeleteAccountResponse{
		Status:       request.Status,
		RequestedAt:  request.RequestedAt,
		CleanupAfter: request.CleanupAfter,
	})
}
