package handlers

import (
	"errors"
	"log"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

const accountDeletionConfirmation = "DELETE"

var accountDeletionReceiptPattern = regexp.MustCompile(`^mta_del_[A-Za-z0-9_-]{43}$`)

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
	if body.DeletionReceiptToken != "" && !accountDeletionReceiptPattern.MatchString(body.DeletionReceiptToken) {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error: "invalid_deletion_receipt", Message: "The account deletion receipt is invalid.", Code: http.StatusBadRequest,
		})
		return
	}

	cleanupAfter := time.Now().UTC()
	if h.AudioStorage != nil && h.AudioStorage.IsConfigured() {
		cleanupAfter = cleanupAfter.Add(h.AudioStorage.PresignedURLExpiry() + 5*time.Minute)
	}
	request, err := h.DB.RequestAccountDeletionWithReceipt(
		c.Request.Context(), user.ID, clerkUserID, cleanupAfter, body.DeletionReceiptToken,
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

// AccountDeletionReceiptStatus reveals only whether an unguessable client
// receipt reached the committed deletion transaction. It returns no account,
// provider, or cleanup metadata and remains usable after sessions are purged.
func (h *Handler) AccountDeletionReceiptStatus(c *gin.Context) {
	c.Header("Cache-Control", "no-store")
	var body models.AccountDeletionReceiptRequest
	if err := c.ShouldBindJSON(&body); err != nil ||
		!accountDeletionReceiptPattern.MatchString(body.DeletionReceiptToken) {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error: "invalid_deletion_receipt", Message: "The account deletion receipt is invalid.", Code: http.StatusBadRequest,
		})
		return
	}
	confirmed, err := h.DB.HasAccountDeletionReceipt(c.Request.Context(), body.DeletionReceiptToken)
	if err != nil {
		log.Printf("check account deletion receipt: %v", err)
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{
			Error: "account_deletion_status_unavailable", Message: "Could not confirm account deletion.", Code: http.StatusServiceUnavailable,
		})
		return
	}
	c.JSON(http.StatusOK, gin.H{"confirmed": confirmed})
}
