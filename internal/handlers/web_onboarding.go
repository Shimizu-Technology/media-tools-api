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

const (
	webOnboardingCookiePath   = "/api/v1/auth/web/onboarding"
	webOnboardingCookieMaxAge = 15 * 60
	webOnboardingRequiredAge  = 24 * 60 * 60
)

type transferWebOnboardingRequest struct {
	Kind  string `json:"kind" binding:"required"`
	Token string `json:"token" binding:"required"`
}

// TransferOnboardingFragment moves the one-time URL fragment into a narrow,
// host-only HttpOnly cookie. Exact Origin is the CSRF boundary before a
// readable double-submit secret exists.
func (h *WebSessionHandler) TransferOnboardingFragment(c *gin.Context) {
	if !h.validOrigin(c) {
		c.JSON(http.StatusForbidden, models.ErrorResponse{Error: "origin_invalid", Message: "Use the Media Tools app to continue", Code: http.StatusForbidden})
		return
	}
	var req transferWebOnboardingRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "invalid_join_link", Message: "This setup link is invalid or incomplete", Code: http.StatusBadRequest})
		return
	}
	req.Kind = strings.TrimSpace(req.Kind)
	req.Token = strings.TrimSpace(req.Token)
	if !validWebOnboardingSecret(req.Kind, req.Token) {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "invalid_join_link", Message: "This setup link is invalid or incomplete", Code: http.StatusBadRequest})
		return
	}

	secretName := onboardingSecretCookie(req.Kind)
	otherName := middleware.WebInvitationCookie
	if secretName == otherName {
		otherName = middleware.WebOnboardingRescueCookie
	}
	if required, err := c.Cookie(middleware.WebOnboardingRequiredCookie); err == nil && required != "" {
		c.JSON(http.StatusConflict, models.ErrorResponse{Error: "onboarding_in_progress", Message: "Finish the current account setup before opening another link", Code: http.StatusConflict})
		return
	}
	if access, err := c.Cookie(middleware.WebAccessCookie); err == nil && access != "" {
		user, _, lookupErr := h.db.GetUserByFirstPartyAccessToken(c.Request.Context(), access)
		switch {
		case lookupErr == nil && user.OnboardingRequired:
			c.JSON(http.StatusConflict, models.ErrorResponse{Error: "onboarding_in_progress", Message: "Finish the current account setup before opening another link", Code: http.StatusConflict})
			return
		case lookupErr == nil, errors.Is(lookupErr, database.ErrSessionInvalid):
			// A completed account or expired access token does not block a new link.
		default:
			log.Printf("check existing web onboarding account: %v", lookupErr)
			c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "onboarding_unavailable", Message: "Could not safely open this setup link; retry", Code: http.StatusServiceUnavailable})
			return
		}
	}
	if other, err := c.Cookie(otherName); err == nil && other != "" {
		c.JSON(http.StatusConflict, models.ErrorResponse{Error: "onboarding_in_progress", Message: "Finish the current account setup before opening another link", Code: http.StatusConflict})
		return
	}
	if current, err := c.Cookie(secretName); err == nil && current != "" && current != req.Token {
		c.JSON(http.StatusConflict, models.ErrorResponse{Error: "onboarding_in_progress", Message: "Finish the current account setup before opening another link", Code: http.StatusConflict})
		return
	}

	csrf, err := webRandomToken("mta_csrf_")
	if err != nil {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "onboarding_unavailable", Message: "Could not secure this setup link; retry", Code: http.StatusServiceUnavailable})
		return
	}
	if pending, err := c.Cookie(middleware.WebOnboardingPendingCookie); err == nil && database.ValidFirstPartyRefreshToken(pending) {
		h.setCookie(c, secretName, req.Token, webOnboardingCookieMaxAge, true, webOnboardingCookiePath)
		h.setCookie(c, middleware.WebCSRFCookie, csrf, webRefreshMaxAge, false, "/")
		c.Header("Cache-Control", "no-store")
		c.Status(http.StatusNoContent)
		return
	}
	successor, err := webRandomToken("mta_rt_")
	if err != nil {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "onboarding_unavailable", Message: "Could not secure this setup link; retry", Code: http.StatusServiceUnavailable})
		return
	}
	h.setCookie(c, secretName, req.Token, webOnboardingCookieMaxAge, true, webOnboardingCookiePath)
	h.setCookie(c, otherName, "", -1, true, webOnboardingCookiePath)
	h.setCookie(c, middleware.WebOnboardingPendingCookie, successor, webOnboardingCookieMaxAge, true, webOnboardingCookiePath)
	h.setCookie(c, middleware.WebCSRFCookie, csrf, webRefreshMaxAge, false, "/")
	c.Header("Cache-Control", "no-store")
	c.Status(http.StatusNoContent)
}

// PrepareOnboardingCommit replaces only a missing or stale successor. The
// transferred bearer credential remains HttpOnly and is never returned to JS.
func (h *WebSessionHandler) PrepareOnboardingCommit(c *gin.Context) {
	if !h.validOrigin(c) {
		c.JSON(http.StatusForbidden, models.ErrorResponse{Error: "origin_invalid", Message: "Use the Media Tools app to continue", Code: http.StatusForbidden})
		return
	}
	if _, _, ok := h.webOnboardingSecret(c); !ok {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "onboarding_not_prepared", Message: "Open your invitation or account rescue link again", Code: http.StatusBadRequest})
		return
	}
	csrf, err := webRandomToken("mta_csrf_")
	if err != nil {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "onboarding_unavailable", Message: "Could not prepare account setup; retry", Code: http.StatusServiceUnavailable})
		return
	}
	if pending, err := c.Cookie(middleware.WebOnboardingPendingCookie); err == nil && database.ValidFirstPartyRefreshToken(pending) {
		h.setCookie(c, middleware.WebCSRFCookie, csrf, webRefreshMaxAge, false, "/")
		c.Header("Cache-Control", "no-store")
		c.Status(http.StatusNoContent)
		return
	}
	successor, err := webRandomToken("mta_rt_")
	if err != nil {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "onboarding_unavailable", Message: "Could not prepare account setup; retry", Code: http.StatusServiceUnavailable})
		return
	}
	h.setCookie(c, middleware.WebOnboardingPendingCookie, successor, webOnboardingCookieMaxAge, true, webOnboardingCookiePath)
	h.setCookie(c, middleware.WebCSRFCookie, csrf, webRefreshMaxAge, false, "/")
	c.Header("Cache-Control", "no-store")
	c.Status(http.StatusNoContent)
}

// CommitWebOnboarding redeems the protected invitation or rescue credential
// and writes the resulting session only to HttpOnly cookies.
func (h *WebSessionHandler) CommitWebOnboarding(c *gin.Context) {
	if h.rejectCSRF(c) {
		return
	}
	kind, secret, ok := h.webOnboardingSecret(c)
	if !ok {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "onboarding_not_prepared", Message: "Open your invitation or account rescue link again", Code: http.StatusBadRequest})
		return
	}
	successor, err := c.Cookie(middleware.WebOnboardingPendingCookie)
	if err != nil || !database.ValidFirstPartyRefreshToken(successor) {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "onboarding_not_prepared", Message: "Prepare account setup again", Code: http.StatusBadRequest})
		return
	}
	csrf, err := webRandomToken("mta_csrf_")
	if err != nil {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "onboarding_unavailable", Message: "Could not finish account setup; retry", Code: http.StatusServiceUnavailable})
		return
	}
	existing := h.cookieCredentials(c,
		middleware.WebRefreshCookie,
		middleware.WebPendingCookie,
		middleware.WebRecoveryPendingCookie,
	)
	var pair *database.AuthTokenPair
	if kind == "invite" {
		pair, err = h.db.RedeemWebInvitation(c.Request.Context(), secret, successor, existing)
	} else {
		pair, err = h.db.RedeemWebOnboardingReissue(c.Request.Context(), secret, successor, existing)
	}
	switch {
	case err == nil:
		h.setPair(c, pair)
		h.clearOnboardingTransfer(c)
		h.setCookie(c, middleware.WebOnboardingRequiredCookie, "required", webOnboardingRequiredAge, true, "/api/v1")
		h.setCookie(c, middleware.WebCSRFCookie, csrf, webRefreshMaxAge, false, "/")
		c.Header("Cache-Control", "no-store")
		c.JSON(http.StatusCreated, gin.H{
			"authenticated":       true,
			"onboarding_required": true,
			"user_id":             pair.UserID,
			"access_expires_at":   pair.AccessExpiresAt.UTC().Format(time.RFC3339Nano),
		})
	case errors.Is(err, database.ErrInvalidSuccessorToken):
		h.clearOnboardingPending(c)
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "onboarding_not_prepared", Message: "Prepare account setup again", Code: http.StatusBadRequest})
	case errors.Is(err, database.ErrInvitationInvalid), errors.Is(err, database.ErrOnboardingReissueInvalid):
		h.clearOnboardingTransfer(c)
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{Error: "invalid_join_link", Message: "This setup link is invalid, expired, or already used", Code: http.StatusUnauthorized})
	case errors.Is(err, database.ErrInvitationEmailExists):
		h.clearOnboardingTransfer(c)
		c.JSON(http.StatusConflict, models.ErrorResponse{Error: "account_exists", Message: "This invitation can no longer create an account", Code: http.StatusConflict})
	case errors.Is(err, database.ErrOnboardingReissueNotAllowed):
		h.clearOnboardingTransfer(c)
		c.JSON(http.StatusConflict, models.ErrorResponse{Error: "account_already_secured", Message: "This account already has a sign-in recovery method", Code: http.StatusConflict})
	default:
		log.Printf("commit web onboarding: %v", err)
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "onboarding_unavailable", Message: "Could not finish account setup; retry", Code: http.StatusServiceUnavailable})
	}
}

// WebOnboardingStatus returns only non-secret progress metadata. It can be
// called before redemption so a reload can resume from HttpOnly cookies.
func (h *WebSessionHandler) WebOnboardingStatus(c *gin.Context) {
	kind, _, pending := h.webOnboardingSecret(c)
	response := gin.H{
		"pending":             pending,
		"kind":                kind,
		"session_ready":       false,
		"onboarding_required": false,
		"passkeys":            0,
		"recovery_codes":      0,
		"complete":            false,
	}
	access, err := c.Cookie(middleware.WebAccessCookie)
	if err != nil {
		c.Header("Cache-Control", "no-store")
		c.JSON(http.StatusOK, response)
		return
	}
	user, _, err := h.db.GetUserByFirstPartyAccessToken(c.Request.Context(), access)
	if errors.Is(err, database.ErrSessionInvalid) {
		c.Header("Cache-Control", "no-store")
		c.JSON(http.StatusOK, response)
		return
	}
	if err != nil {
		log.Printf("load web onboarding session: %v", err)
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "onboarding_unavailable", Message: "Could not check account setup; retry", Code: http.StatusServiceUnavailable})
		return
	}
	response["onboarding_required"] = user.OnboardingRequired
	if !user.OnboardingRequired {
		response["session_ready"] = true
		c.Header("Cache-Control", "no-store")
		c.JSON(http.StatusOK, response)
		return
	}
	passkeys, recoveryCodes, err := h.db.OnboardingSecurityStatus(c.Request.Context(), user.ID)
	if err != nil {
		log.Printf("load web onboarding security status: %v", err)
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "onboarding_unavailable", Message: "Could not check account setup; retry", Code: http.StatusServiceUnavailable})
		return
	}
	response["session_ready"] = true
	response["passkeys"] = passkeys
	response["recovery_codes"] = recoveryCodes
	response["complete"] = passkeys > 0 && recoveryCodes > 0
	c.Header("Cache-Control", "no-store")
	c.JSON(http.StatusOK, response)
}

// CompleteWebOnboarding clears the server-persisted requirement only after a
// transaction confirms both durable recovery factors for the current account.
func (h *WebSessionHandler) CompleteWebOnboarding(c *gin.Context) {
	if h.rejectCSRF(c) {
		return
	}
	access, err := c.Cookie(middleware.WebAccessCookie)
	if err != nil {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{Error: "unauthorized", Message: "Sign in again to finish setup", Code: http.StatusUnauthorized})
		return
	}
	user, _, err := h.db.GetUserByFirstPartyAccessToken(c.Request.Context(), access)
	if errors.Is(err, database.ErrSessionInvalid) {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{Error: "unauthorized", Message: "Sign in again to finish setup", Code: http.StatusUnauthorized})
		return
	}
	if err != nil {
		log.Printf("load web onboarding completion session: %v", err)
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "onboarding_unavailable", Message: "Could not finish account setup; retry", Code: http.StatusServiceUnavailable})
		return
	}
	completed, err := h.db.CompleteOnboarding(c.Request.Context(), user.ID)
	if err != nil {
		log.Printf("verify web onboarding completion: %v", err)
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "onboarding_unavailable", Message: "Could not finish account setup; retry", Code: http.StatusServiceUnavailable})
		return
	}
	if !completed {
		c.JSON(http.StatusConflict, models.ErrorResponse{Error: "onboarding_incomplete", Message: "Add a passkey and save recovery codes before continuing", Code: http.StatusConflict})
		return
	}
	h.clearOnboardingAll(c)
	c.Header("Cache-Control", "no-store")
	c.Status(http.StatusNoContent)
}

func validWebOnboardingSecret(kind, token string) bool {
	switch kind {
	case "invite":
		return database.ValidInvitationToken(token)
	case "onboarding":
		return database.ValidOnboardingReissueToken(token)
	default:
		return false
	}
}

func onboardingSecretCookie(kind string) string {
	if kind == "invite" {
		return middleware.WebInvitationCookie
	}
	return middleware.WebOnboardingRescueCookie
}

func (h *WebSessionHandler) webOnboardingSecret(c *gin.Context) (kind, token string, ok bool) {
	invite, inviteErr := c.Cookie(middleware.WebInvitationCookie)
	rescue, rescueErr := c.Cookie(middleware.WebOnboardingRescueCookie)
	inviteValid := inviteErr == nil && database.ValidInvitationToken(invite)
	rescueValid := rescueErr == nil && database.ValidOnboardingReissueToken(rescue)
	if inviteValid && !rescueValid {
		return "invite", invite, true
	}
	if rescueValid && !inviteValid {
		return "onboarding", rescue, true
	}
	return "", "", false
}

func (h *WebSessionHandler) cookieCredentials(c *gin.Context, names ...string) []string {
	credentials := make([]string, 0, len(names))
	for _, name := range names {
		if credential, err := c.Cookie(name); err == nil && credential != "" {
			credentials = append(credentials, credential)
		}
	}
	return credentials
}

func (h *WebSessionHandler) clearOnboardingPending(c *gin.Context) {
	h.setCookie(c, middleware.WebOnboardingPendingCookie, "", -1, true, webOnboardingCookiePath)
}

func (h *WebSessionHandler) clearOnboardingTransfer(c *gin.Context) {
	h.setCookie(c, middleware.WebInvitationCookie, "", -1, true, webOnboardingCookiePath)
	h.setCookie(c, middleware.WebOnboardingRescueCookie, "", -1, true, webOnboardingCookiePath)
	h.clearOnboardingPending(c)
}

func (h *WebSessionHandler) clearOnboardingAll(c *gin.Context) {
	h.clearOnboardingTransfer(c)
	h.setCookie(c, middleware.WebOnboardingRequiredCookie, "", -1, true, "/api/v1")
}
