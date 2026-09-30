package handlers

import (
	"errors"
	"log"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
)

func (h *Handler) RecoveryCodeStatus(c *gin.Context) {
	user := middleware.GetUser(c)
	if user == nil || !strings.HasPrefix(middleware.AuthSessionBinding(c), "first-party:") {
		passkeyError(c, http.StatusUnauthorized, "unauthorized", "A signed-in device session is required")
		return
	}
	count, err := h.DB.RemainingRecoveryCodes(c.Request.Context(), user.ID)
	if err != nil {
		log.Printf("count recovery codes for user %s: %v", user.ID, err)
		passkeyError(c, http.StatusServiceUnavailable, "authentication_unavailable", "Could not check recovery codes")
		return
	}
	c.Header("Cache-Control", "no-store")
	c.JSON(http.StatusOK, gin.H{"remaining": count})
}

func (h *Handler) BeginRecoveryCodeRotation(c *gin.Context) {
	user := middleware.GetUser(c)
	if user == nil || !strings.HasPrefix(middleware.AuthSessionBinding(c), "first-party:") {
		passkeyError(c, http.StatusUnauthorized, "unauthorized", "A signed-in device session is required")
		return
	}
	rotation, err := h.DB.BeginRecoveryCodeRotation(c.Request.Context(), user.ID)
	if err != nil {
		log.Printf("begin recovery code rotation for user %s: %v", user.ID, err)
		passkeyError(c, http.StatusServiceUnavailable, "authentication_unavailable", "Could not create recovery codes")
		return
	}
	c.Header("Cache-Control", "no-store")
	c.JSON(http.StatusCreated, gin.H{"rotation_id": rotation.ID, "codes": rotation.Codes})
}

type confirmRecoveryCodeRotationRequest struct {
	RotationID string `json:"rotation_id" binding:"required"`
}

func (h *Handler) ConfirmRecoveryCodeRotation(c *gin.Context) {
	user := middleware.GetUser(c)
	if user == nil || !strings.HasPrefix(middleware.AuthSessionBinding(c), "first-party:") {
		passkeyError(c, http.StatusUnauthorized, "unauthorized", "A signed-in device session is required")
		return
	}
	var req confirmRecoveryCodeRotationRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		passkeyError(c, http.StatusBadRequest, "invalid_request", "Rotation ID is required")
		return
	}
	count, err := h.DB.ConfirmRecoveryCodeRotation(c.Request.Context(), user.ID, req.RotationID)
	if errors.Is(err, database.ErrRecoveryRotationInvalid) {
		passkeyError(c, http.StatusNotFound, "recovery_rotation_not_found", "Recovery code rotation is invalid or expired")
		return
	}
	if err != nil {
		log.Printf("confirm recovery code rotation for user %s: %v", user.ID, err)
		passkeyError(c, http.StatusServiceUnavailable, "authentication_unavailable", "Could not confirm recovery codes")
		return
	}
	c.Header("Cache-Control", "no-store")
	c.JSON(http.StatusOK, gin.H{"remaining": count})
}

type redeemRecoveryCodeRequest struct {
	Code             string `json:"code" binding:"required"`
	ClientType       string `json:"client_type" binding:"required"`
	DeviceName       string `json:"device_name"`
	NextRefreshToken string `json:"next_refresh_token" binding:"required"`
}

func (h *Handler) RedeemRecoveryCode(c *gin.Context) {
	var req redeemRecoveryCodeRequest
	if err := c.ShouldBindJSON(&req); err != nil ||
		(req.ClientType != "ios" && req.ClientType != "android") ||
		len(strings.TrimSpace(req.DeviceName)) > 80 {
		passkeyError(c, http.StatusBadRequest, "invalid_request", "Recovery code, saved refresh token, and valid native client type are required")
		return
	}
	pair, err := h.DB.RedeemRecoveryCode(c.Request.Context(), req.Code, req.ClientType, req.DeviceName, req.NextRefreshToken)
	switch {
	case err == nil:
		c.Header("Cache-Control", "no-store")
		c.JSON(http.StatusCreated, pair)
	case errors.Is(err, database.ErrRecoveryCodeInvalid):
		passkeyError(c, http.StatusUnauthorized, "invalid_recovery_code", "Recovery code is invalid or already used")
	case errors.Is(err, database.ErrInvalidSuccessorToken):
		passkeyError(c, http.StatusBadRequest, "invalid_request", "A valid saved refresh token is required")
	default:
		log.Printf("redeem recovery code: %v", err)
		passkeyError(c, http.StatusServiceUnavailable, "authentication_unavailable", "Could not complete recovery sign-in")
	}
}
