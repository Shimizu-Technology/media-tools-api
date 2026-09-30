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

const onboardingReissueURLPrefix = "https://media.shimizu-technology.com/join#onboarding="

type createOnboardingReissueRequest struct {
	UserID string `json:"user_id" binding:"required"`
}

type createOnboardingReissueResponse struct {
	ID        string `json:"id"`
	UserID    string `json:"user_id"`
	Email     string `json:"email"`
	Name      string `json:"name"`
	ExpiresAt string `json:"expires_at"`
	Token     string `json:"token"`
	JoinURL   string `json:"join_url"`
}

func (h *Handler) CreateOnboardingReissue(c *gin.Context) {
	if h.AdminAPIKey == "" {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "admin_key_required", Message: "Onboarding rescue requires a configured admin key.", Code: http.StatusServiceUnavailable})
		return
	}
	providedKey := c.GetHeader("X-Admin-Key")
	if providedKey == "" {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{Error: "unauthorized", Message: "X-Admin-Key header is required", Code: http.StatusUnauthorized})
		return
	}
	if !adminKeyMatches(providedKey, h.AdminAPIKey) {
		c.JSON(http.StatusForbidden, models.ErrorResponse{Error: "forbidden", Message: "Invalid admin key", Code: http.StatusForbidden})
		return
	}
	var req createOnboardingReissueRequest
	if err := c.ShouldBindJSON(&req); err != nil || strings.TrimSpace(req.UserID) == "" {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "invalid_request", Message: "A user ID is required", Code: http.StatusBadRequest})
		return
	}
	reissue, token, err := h.DB.CreateOnboardingReissue(c.Request.Context(), req.UserID)
	switch {
	case err == nil:
		c.Header("Cache-Control", "no-store")
		c.JSON(http.StatusCreated, createOnboardingReissueResponse{
			ID: reissue.ID, UserID: reissue.UserID, Email: reissue.Email, Name: reissue.Name,
			ExpiresAt: reissue.ExpiresAt.Format("2006-01-02T15:04:05Z07:00"),
			Token:     token, JoinURL: onboardingReissueURLPrefix + token,
		})
	case errors.Is(err, database.ErrOnboardingAccountNotFound):
		c.JSON(http.StatusNotFound, models.ErrorResponse{Error: "account_not_found", Message: "Account was not found", Code: http.StatusNotFound})
	case errors.Is(err, database.ErrOnboardingReissueNotAllowed):
		c.JSON(http.StatusConflict, models.ErrorResponse{Error: "account_already_secured", Message: "This account already has a passkey or active recovery code", Code: http.StatusConflict})
	default:
		log.Printf("create onboarding rescue: %v", err)
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "onboarding_unavailable", Message: "Could not create onboarding rescue", Code: http.StatusServiceUnavailable})
	}
}

type redeemOnboardingReissueRequest struct {
	Token            string `json:"token" binding:"required"`
	ClientType       string `json:"client_type" binding:"required"`
	DeviceName       string `json:"device_name"`
	NextRefreshToken string `json:"next_refresh_token" binding:"required"`
}

func (h *Handler) RedeemOnboardingReissue(c *gin.Context) {
	var req redeemOnboardingReissueRequest
	if err := c.ShouldBindJSON(&req); err != nil ||
		(req.ClientType != "ios" && req.ClientType != "android") ||
		len(strings.TrimSpace(req.DeviceName)) > 80 {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "invalid_request", Message: "A rescue link, saved refresh token, and valid native client type are required", Code: http.StatusBadRequest})
		return
	}
	pair, err := h.DB.RedeemOnboardingReissue(c.Request.Context(), req.Token, req.ClientType, req.DeviceName, req.NextRefreshToken)
	switch {
	case err == nil:
		c.Header("Cache-Control", "no-store")
		c.JSON(http.StatusCreated, pair)
	case errors.Is(err, database.ErrOnboardingReissueInvalid):
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{Error: "invalid_onboarding_rescue", Message: "Onboarding rescue is invalid or already used", Code: http.StatusUnauthorized})
	case errors.Is(err, database.ErrOnboardingReissueNotAllowed):
		c.JSON(http.StatusConflict, models.ErrorResponse{Error: "account_already_secured", Message: "This account already has a sign-in recovery method", Code: http.StatusConflict})
	case errors.Is(err, database.ErrInvalidSuccessorToken):
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "invalid_request", Message: "A valid saved refresh token is required", Code: http.StatusBadRequest})
	default:
		log.Printf("redeem onboarding rescue: %v", err)
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "onboarding_unavailable", Message: "Could not redeem onboarding rescue", Code: http.StatusServiceUnavailable})
	}
}
