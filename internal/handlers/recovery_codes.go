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

func (h *Handler) ReplaceRecoveryCodes(c *gin.Context) {
	user := middleware.GetUser(c)
	if user == nil || !strings.HasPrefix(middleware.AuthSessionBinding(c), "first-party:") {
		passkeyError(c, http.StatusUnauthorized, "unauthorized", "A signed-in device session is required")
		return
	}
	codes, err := h.DB.ReplaceRecoveryCodes(c.Request.Context(), user.ID)
	if err != nil {
		log.Printf("replace recovery codes for user %s: %v", user.ID, err)
		passkeyError(c, http.StatusServiceUnavailable, "authentication_unavailable", "Could not create recovery codes")
		return
	}
	c.Header("Cache-Control", "no-store")
	c.JSON(http.StatusCreated, gin.H{"codes": codes})
}

type redeemRecoveryCodeRequest struct {
	Code       string `json:"code" binding:"required"`
	ClientType string `json:"client_type" binding:"required"`
	DeviceName string `json:"device_name"`
}

func (h *Handler) RedeemRecoveryCode(c *gin.Context) {
	var req redeemRecoveryCodeRequest
	if err := c.ShouldBindJSON(&req); err != nil ||
		(req.ClientType != "web" && req.ClientType != "ios" && req.ClientType != "android") ||
		len(strings.TrimSpace(req.DeviceName)) > 80 {
		passkeyError(c, http.StatusBadRequest, "invalid_request", "Recovery code and valid client type are required")
		return
	}
	pair, err := h.DB.RedeemRecoveryCode(c.Request.Context(), req.Code, req.ClientType, req.DeviceName)
	switch {
	case err == nil:
		c.Header("Cache-Control", "no-store")
		c.JSON(http.StatusCreated, pair)
	case errors.Is(err, database.ErrRecoveryCodeInvalid):
		passkeyError(c, http.StatusUnauthorized, "invalid_recovery_code", "Recovery code is invalid or already used")
	default:
		log.Printf("redeem recovery code: %v", err)
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not complete recovery sign-in", Code: http.StatusServiceUnavailable})
	}
}
