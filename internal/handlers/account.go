package handlers

import (
	"errors"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

const accountDeletionConfirmation = "DELETE"

// DeleteAccount begins a durable, cross-system deletion. The database purge
// commits before the response; object storage and Clerk finish asynchronously.
// DELETE /api/v1/account
func (h *Handler) DeleteAccount(c *gin.Context) {
	user := middleware.GetUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{
			Error:   "unauthorized",
			Message: "Sign in to delete your account.",
			Code:    http.StatusUnauthorized,
		})
		return
	}
	var clerkUserID *string
	if user.ClerkID != nil && strings.TrimSpace(*user.ClerkID) != "" {
		trimmed := strings.TrimSpace(*user.ClerkID)
		clerkUserID = &trimmed
		if !h.ClerkAccountDeletionEnabled {
			c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{
				Error:   "account_deletion_unavailable",
				Message: "Account deletion is temporarily unavailable. Please contact support.",
				Code:    http.StatusServiceUnavailable,
			})
			return
		}
	} else if !strings.HasPrefix(middleware.AuthSessionBinding(c), "first-party:") {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{
			Error:   "first_party_session_required",
			Message: "A signed-in device session is required to delete this account.",
			Code:    http.StatusUnauthorized,
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
		c.Request.Context(), user.ID, clerkUserID, cleanupAfter,
	)
	if err != nil {
		if errors.Is(err, database.ErrAccountDeletionAlreadyRequested) {
			c.JSON(http.StatusConflict, models.ErrorResponse{
				Error:   "account_deletion_already_requested",
				Message: "Account deletion has already been requested.",
				Code:    http.StatusConflict,
			})
			return
		}
		log.Printf("request account deletion for user %s: %v", user.ID, err)
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
