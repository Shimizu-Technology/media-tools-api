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

const webRecoveryPendingMaxAge = 24 * 60 * 60

// PrepareRecoveryCodeLogin installs the refresh successor in a host-only,
// HttpOnly cookie before a one-time recovery code can be consumed. It leaves
// any current browser session intact until redemption commits successfully.
func (h *WebSessionHandler) PrepareRecoveryCodeLogin(c *gin.Context) {
	if !h.validOrigin(c) {
		c.JSON(http.StatusForbidden, models.ErrorResponse{Error: "origin_invalid", Message: "Use the Media Tools app to sign in", Code: http.StatusForbidden})
		return
	}
	csrf, err := webRandomToken("mta_csrf_")
	if err != nil {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not prepare recovery sign-in", Code: http.StatusServiceUnavailable})
		return
	}
	if pending, err := c.Cookie(middleware.WebRecoveryPendingCookie); err == nil && database.ValidFirstPartyRefreshToken(pending) {
		h.setCookie(c, middleware.WebCSRFCookie, csrf, webRefreshMaxAge, false, "/")
		c.Header("Cache-Control", "no-store")
		c.Status(http.StatusNoContent)
		return
	}
	successor, err := webRandomToken("mta_rt_")
	if err != nil {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not prepare recovery sign-in", Code: http.StatusServiceUnavailable})
		return
	}
	// Session scope lets a later invitation/rescue handoff revoke a committed
	// response-loss successor in the same transaction as the account switch.
	h.setCookie(c, middleware.WebRecoveryPendingCookie, successor, webRecoveryPendingMaxAge, true, "/api/v1/auth/web/session")
	h.setCookie(c, middleware.WebCSRFCookie, csrf, webRefreshMaxAge, false, "/")
	c.Header("Cache-Control", "no-store")
	c.Status(http.StatusNoContent)
}

type finishWebRecoveryCodeLoginRequest struct {
	Code string `json:"code"`
}

// FinishRecoveryCodeLogin writes credentials only to HttpOnly cookies. An
// omitted code asks the database to recover an earlier committed redemption
// using the exact successor from PrepareRecoveryCodeLogin.
func (h *WebSessionHandler) FinishRecoveryCodeLogin(c *gin.Context) {
	if h.rejectCSRF(c) {
		return
	}
	var req finishWebRecoveryCodeLoginRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "invalid_request", Message: "Enter a valid recovery code", Code: http.StatusBadRequest})
		return
	}
	req.Code = strings.TrimSpace(req.Code)
	if len(req.Code) > 80 {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{Error: "invalid_recovery_code", Message: "Recovery code is invalid or already used", Code: http.StatusUnauthorized})
		return
	}
	successor, err := c.Cookie(middleware.WebRecoveryPendingCookie)
	if err != nil || !database.ValidFirstPartyRefreshToken(successor) {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "sign_in_not_prepared", Message: "Start recovery sign-in again", Code: http.StatusBadRequest})
		return
	}
	existing := make([]string, 0, 3)
	for _, name := range []string{middleware.WebRefreshCookie, middleware.WebPendingCookie, middleware.WebOnboardingPendingCookie} {
		if credential, err := c.Cookie(name); err == nil && credential != "" {
			existing = append(existing, credential)
		}
	}
	pair, err := h.db.RedeemWebRecoveryCode(c.Request.Context(), req.Code, successor, existing)
	switch {
	case err == nil:
		csrf, csrfErr := webRandomToken("mta_csrf_")
		if csrfErr != nil {
			log.Printf("rotate CSRF after browser recovery sign-in: %v", csrfErr)
			c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not complete recovery sign-in", Code: http.StatusServiceUnavailable})
			return
		}
		h.setPair(c, pair)
		h.clearRecoveryPending(c)
		h.clearOnboardingAll(c)
		h.setCookie(c, middleware.WebCSRFCookie, csrf, webRefreshMaxAge, false, "/")
		c.Header("Cache-Control", "no-store")
		c.JSON(http.StatusCreated, gin.H{
			"authenticated":     true,
			"user_id":           pair.UserID,
			"access_expires_at": pair.AccessExpiresAt.UTC().Format(time.RFC3339Nano),
		})
	case errors.Is(err, database.ErrRecoveryCodeInvalid):
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{Error: "invalid_recovery_code", Message: "Recovery code is invalid or already used", Code: http.StatusUnauthorized})
	case errors.Is(err, database.ErrInvalidSuccessorToken):
		h.clearRecoveryPending(c)
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "sign_in_not_prepared", Message: "Start recovery sign-in again", Code: http.StatusBadRequest})
	default:
		log.Printf("redeem browser recovery code: %v", err)
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not complete recovery sign-in; retry", Code: http.StatusServiceUnavailable})
	}
}
