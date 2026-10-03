package handlers

import (
	"errors"
	"log"
	"net/http"
	"unicode/utf8"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

const webPasswordPendingMaxAge = 24 * 60 * 60

func (h *WebSessionHandler) PreparePasswordLogin(c *gin.Context) {
	if !h.validOrigin(c) {
		c.JSON(http.StatusForbidden, models.ErrorResponse{Error: "origin_invalid", Message: "Use the Media Tools app to sign in", Code: http.StatusForbidden})
		return
	}
	csrf, err := webRandomToken("mta_csrf_")
	if err != nil {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not prepare password sign-in", Code: http.StatusServiceUnavailable})
		return
	}
	if pending, err := c.Cookie(middleware.WebPasswordPendingCookie); err == nil && database.ValidFirstPartyRefreshToken(pending) {
		h.setCookie(c, middleware.WebCSRFCookie, csrf, webRefreshMaxAge, false, "/")
		c.Header("Cache-Control", "no-store")
		c.Status(http.StatusNoContent)
		return
	}
	successor, err := webRandomToken("mta_rt_")
	if err != nil {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not prepare password sign-in", Code: http.StatusServiceUnavailable})
		return
	}
	h.setCookie(c, middleware.WebPasswordPendingCookie, successor, webPasswordPendingMaxAge, true, "/api/v1/auth/web/session")
	h.setCookie(c, middleware.WebCSRFCookie, csrf, webRefreshMaxAge, false, "/")
	c.Header("Cache-Control", "no-store")
	c.Status(http.StatusNoContent)
}

type finishWebPasswordLoginRequest struct {
	Email    string `json:"email" binding:"required"`
	Password string `json:"password" binding:"required"`
}

func (h *WebSessionHandler) FinishPasswordLogin(c *gin.Context) {
	if h.rejectCSRF(c) {
		return
	}
	var req finishWebPasswordLoginRequest
	if err := c.ShouldBindJSON(&req); err != nil || database.NormalizeLoginEmail(req.Email) == "" || len(req.Email) > 255 || !utf8.ValidString(req.Email) || len(req.Password) == 0 || len(req.Password) > 1024 || !utf8.ValidString(req.Password) {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "invalid_request", Message: "Enter a valid email and password", Code: http.StatusBadRequest})
		return
	}
	successor, err := c.Cookie(middleware.WebPasswordPendingCookie)
	if err != nil || !database.ValidFirstPartyRefreshToken(successor) {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "sign_in_not_prepared", Message: "Start password sign-in again", Code: http.StatusBadRequest})
		return
	}
	existing := make([]string, 0, 4)
	for _, name := range []string{middleware.WebRefreshCookie, middleware.WebPendingCookie, middleware.WebRecoveryPendingCookie, middleware.WebOnboardingPendingCookie} {
		if credential, cookieErr := c.Cookie(name); cookieErr == nil && credential != "" {
			existing = append(existing, credential)
		}
	}
	pair, err := h.auth.createPasswordSession(c.Request.Context(), req.Email, req.Password, "web", "Browser", successor, existing)
	if errors.Is(err, errPasswordRejected) {
		passwordCredentialsRejected(c)
		return
	}
	if err != nil {
		log.Printf("complete browser password sign-in: %v", err)
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not complete password sign-in; retry", Code: http.StatusServiceUnavailable})
		return
	}
	csrf, err := webRandomToken("mta_csrf_")
	if err != nil {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not complete password sign-in; retry", Code: http.StatusServiceUnavailable})
		return
	}
	h.setPair(c, pair)
	h.clearPasswordPending(c)
	h.clearRecoveryPending(c)
	h.clearOnboardingAll(c)
	h.setCookie(c, middleware.WebCSRFCookie, csrf, webRefreshMaxAge, false, "/")
	c.JSON(http.StatusCreated, gin.H{"authenticated": true, "user_id": pair.UserID, "access_expires_at": pair.AccessExpiresAt})
}
