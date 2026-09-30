package handlers

import (
	"errors"
	"log"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

const invitationJoinURLPrefix = "https://media.shimizu-technology.com/join#invite="

type createInvitationRequest struct {
	Email string `json:"email" binding:"required,email"`
	Name  string `json:"name" binding:"required"`
}

type createInvitationResponse struct {
	ID        string `json:"id"`
	Email     string `json:"email"`
	Name      string `json:"name"`
	ExpiresAt string `json:"expires_at"`
	Token     string `json:"token"`
	InviteURL string `json:"invite_url"`
}

func (h *Handler) CreateInvitation(c *gin.Context) {
	if h.AdminAPIKey == "" {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{
			Error:   "admin_key_required",
			Message: "Invitation creation requires a configured admin key.",
			Code:    http.StatusServiceUnavailable,
		})
		return
	}
	providedKey := c.GetHeader("X-Admin-Key")
	if providedKey == "" {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{
			Error:   "unauthorized",
			Message: "X-Admin-Key header is required to create invitations",
			Code:    http.StatusUnauthorized,
		})
		return
	}
	if !adminKeyMatches(providedKey, h.AdminAPIKey) {
		c.JSON(http.StatusForbidden, models.ErrorResponse{
			Error:   "forbidden",
			Message: "Invalid admin key",
			Code:    http.StatusForbidden,
		})
		return
	}

	var req createInvitationRequest
	if err := c.ShouldBindJSON(&req); err != nil || strings.TrimSpace(req.Name) == "" {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_request",
			Message: "Name and email are required",
			Code:    http.StatusBadRequest,
		})
		return
	}
	invitation, token, err := h.DB.CreateInvitation(c.Request.Context(), req.Email, req.Name)
	switch {
	case err == nil:
		c.Header("Cache-Control", "no-store")
		c.JSON(http.StatusCreated, createInvitationResponse{
			ID:        invitation.ID,
			Email:     invitation.Email,
			Name:      invitation.Name,
			ExpiresAt: invitation.ExpiresAt.Format("2006-01-02T15:04:05Z07:00"),
			Token:     token,
			InviteURL: invitationJoinURLPrefix + token,
		})
	case errors.Is(err, database.ErrInvitationEmailExists):
		c.JSON(http.StatusConflict, models.ErrorResponse{
			Error:   "email_taken",
			Message: "An account with this email already exists",
			Code:    http.StatusConflict,
		})
	default:
		log.Printf("create invitation: %v", err)
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{
			Error:   "invitation_unavailable",
			Message: "Could not create invitation",
			Code:    http.StatusServiceUnavailable,
		})
	}
}

type redeemInvitationRequest struct {
	Token            string `json:"token" binding:"required"`
	ClientType       string `json:"client_type" binding:"required"`
	DeviceName       string `json:"device_name"`
	NextRefreshToken string `json:"next_refresh_token" binding:"required"`
}

func (h *Handler) RedeemInvitation(c *gin.Context) {
	var req redeemInvitationRequest
	if err := c.ShouldBindJSON(&req); err != nil ||
		(req.ClientType != "ios" && req.ClientType != "android") ||
		len(strings.TrimSpace(req.DeviceName)) > 80 {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_request",
			Message: "Invitation token, saved refresh token, and valid native client type are required",
			Code:    http.StatusBadRequest,
		})
		return
	}
	pair, err := h.DB.RedeemInvitation(c.Request.Context(), req.Token, req.ClientType, req.DeviceName, req.NextRefreshToken)
	switch {
	case err == nil:
		c.Header("Cache-Control", "no-store")
		c.JSON(http.StatusCreated, pair)
	case errors.Is(err, database.ErrInvitationInvalid):
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{
			Error:   "invalid_invitation",
			Message: "Invitation is invalid or already used",
			Code:    http.StatusUnauthorized,
		})
	case errors.Is(err, database.ErrInvitationEmailExists):
		c.JSON(http.StatusConflict, models.ErrorResponse{
			Error:   "email_taken",
			Message: "An account with this email already exists",
			Code:    http.StatusConflict,
		})
	case errors.Is(err, database.ErrInvalidSuccessorToken):
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_request",
			Message: "A valid saved refresh token is required",
			Code:    http.StatusBadRequest,
		})
	default:
		log.Printf("redeem invitation: %v", err)
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{
			Error:   "invitation_unavailable",
			Message: "Could not redeem invitation",
			Code:    http.StatusServiceUnavailable,
		})
	}
}
