package handlers

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

type bootstrapSessionRequest struct {
	ClientType string `json:"client_type" binding:"required"`
	DeviceName string `json:"device_name"`
}

// BootstrapFirstPartySession is reachable only after ClerkAuth has verified a
// current Clerk identity. It preserves the mapped application user ID.
func (h *Handler) BootstrapFirstPartySession(c *gin.Context) {
	user := middleware.GetUser(c)
	if user == nil || user.ClerkID == nil {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{Error: "unauthorized", Message: "A verified Clerk account is required", Code: http.StatusUnauthorized})
		return
	}
	var req bootstrapSessionRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "invalid_request", Message: "Client type and device name are required", Code: http.StatusBadRequest})
		return
	}
	if err := h.DB.EnsureAuthIdentity(c.Request.Context(), user.ID, "clerk", *user.ClerkID); err != nil {
		c.JSON(http.StatusConflict, models.ErrorResponse{Error: "identity_conflict", Message: "Could not link this identity to the account", Code: http.StatusConflict})
		return
	}
	pair, err := h.DB.CreateFirstPartySession(c.Request.Context(), user.ID, req.ClientType, req.DeviceName)
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{Error: "session_creation_failed", Message: "Could not create device session", Code: http.StatusInternalServerError})
		return
	}
	c.Header("Cache-Control", "no-store")
	c.JSON(http.StatusCreated, pair)
}

type refreshSessionRequest struct {
	RefreshToken string `json:"refresh_token" binding:"required"`
}

func (h *Handler) RefreshFirstPartySession(c *gin.Context) {
	var req refreshSessionRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "invalid_request", Message: "Refresh credential is required", Code: http.StatusBadRequest})
		return
	}
	pair, err := h.DB.RefreshFirstPartySession(c.Request.Context(), req.RefreshToken)
	switch {
	case err == nil:
		c.Header("Cache-Control", "no-store")
		c.JSON(http.StatusOK, pair)
	case errors.Is(err, database.ErrSessionAlreadyRotated):
		c.JSON(http.StatusConflict, models.ErrorResponse{Error: "session_refresh_in_progress", Message: "Session was just refreshed; retry with the latest stored credential", Code: http.StatusConflict})
	case errors.Is(err, database.ErrSessionReplay), errors.Is(err, database.ErrSessionInvalid):
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{Error: "invalid_session", Message: "Sign in again to continue", Code: http.StatusUnauthorized})
	default:
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not refresh session", Code: http.StatusServiceUnavailable})
	}
}

func (h *Handler) ListFirstPartySessions(c *gin.Context) {
	user := middleware.GetUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{Error: "unauthorized", Message: "Sign in to continue", Code: http.StatusUnauthorized})
		return
	}
	sessions, err := h.DB.ListFirstPartySessions(c.Request.Context(), user.ID)
	if err != nil {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not list devices", Code: http.StatusServiceUnavailable})
		return
	}
	c.JSON(http.StatusOK, gin.H{"sessions": sessions})
}

func (h *Handler) RevokeFirstPartySession(c *gin.Context) {
	user := middleware.GetUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{Error: "unauthorized", Message: "Sign in to continue", Code: http.StatusUnauthorized})
		return
	}
	revoked, err := h.DB.RevokeFirstPartySession(c.Request.Context(), user.ID, c.Param("id"))
	if err != nil {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not revoke device", Code: http.StatusServiceUnavailable})
		return
	}
	if !revoked {
		c.JSON(http.StatusNotFound, models.ErrorResponse{Error: "not_found", Message: "Device session not found", Code: http.StatusNotFound})
		return
	}
	c.Status(http.StatusNoContent)
}
