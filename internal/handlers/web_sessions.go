package handlers

import (
	"crypto/rand"
	"encoding/base64"
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

const webRefreshMaxAge = 365 * 24 * 60 * 60

type WebSessionHandler struct {
	db             *database.DB
	auth           *Handler
	secure         bool
	allowedOrigins []string
}

func NewWebSessionHandler(db *database.DB, auth *Handler, secure bool, allowedOrigins []string) *WebSessionHandler {
	return &WebSessionHandler{db: db, auth: auth, secure: secure, allowedOrigins: allowedOrigins}
}

func webRandomToken(prefix string) (string, error) {
	bytes := make([]byte, 32)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	return prefix + base64.RawURLEncoding.EncodeToString(bytes), nil
}

func (h *WebSessionHandler) setCookie(c *gin.Context, name, value string, maxAge int, httpOnly bool, path string) {
	http.SetCookie(c.Writer, &http.Cookie{
		Name: name, Value: value, Path: path, MaxAge: maxAge,
		Secure: h.secure, HttpOnly: httpOnly, SameSite: http.SameSiteStrictMode,
	})
}

func (h *WebSessionHandler) clear(c *gin.Context) {
	h.setCookie(c, middleware.WebAccessCookie, "", -1, true, "/api/v1")
	h.setCookie(c, middleware.WebRefreshCookie, "", -1, true, "/api/v1/auth/web/session")
	h.clearPending(c)
	h.clearPasswordPending(c)
	h.clearRecoveryPending(c)
	h.clearOnboardingAll(c)
	h.setCookie(c, middleware.WebCSRFCookie, "", -1, false, "/")
}

func (h *WebSessionHandler) clearPasswordPending(c *gin.Context) {
	h.setCookie(c, middleware.WebPasswordPendingCookie, "", -1, true, "/api/v1/auth/web/session")
}

func (h *WebSessionHandler) clearRecoveryPending(c *gin.Context) {
	h.setCookie(c, middleware.WebRecoveryPendingCookie, "", -1, true, "/api/v1/auth/web/session")
}

func (h *WebSessionHandler) clearPending(c *gin.Context) {
	h.setCookie(c, middleware.WebPendingCookie, "", -1, true, "/api/v1/auth/web/session")
}

func (h *WebSessionHandler) setPair(c *gin.Context, pair *database.AuthTokenPair) {
	h.setCookie(c, middleware.WebAccessCookie, pair.AccessToken, int(time.Until(pair.AccessExpiresAt).Seconds()), true, "/api/v1")
	h.setCookie(c, middleware.WebRefreshCookie, pair.RefreshToken, webRefreshMaxAge, true, "/api/v1/auth/web/session")
	h.clearPending(c)
	c.Header("Cache-Control", "no-store")
}

func (h *WebSessionHandler) validOrigin(c *gin.Context) bool {
	origin := c.GetHeader("Origin")
	for _, allowed := range h.allowedOrigins {
		if origin != "" && origin == allowed {
			return true
		}
	}
	return false
}

func (h *WebSessionHandler) rejectCSRF(c *gin.Context) bool {
	if middleware.ValidWebCookieMutation(c, h.allowedOrigins) {
		return false
	}
	c.JSON(http.StatusForbidden, models.ErrorResponse{Error: "csrf_invalid", Message: "Refresh the page and try again", Code: http.StatusForbidden})
	return true
}

// Bootstrap exchanges an already verified Clerk identity for a same-origin
// browser session. PrepareBootstrap has already stored the exact refresh
// successor outside JavaScript, so an identical retry recovers the same
// session instead of creating an orphan after a lost response.
func (h *WebSessionHandler) Bootstrap(c *gin.Context) {
	if h.rejectCSRF(c) {
		return
	}
	user := middleware.GetUser(c)
	if user == nil || user.ClerkID == nil || strings.TrimSpace(*user.ClerkID) == "" {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{Error: "unauthorized", Message: "A verified account is required", Code: http.StatusUnauthorized})
		return
	}
	successor, err := c.Cookie(middleware.WebPendingCookie)
	if err != nil || !database.ValidFirstPartyRefreshToken(successor) {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "session_not_prepared", Message: "Prepare browser sign-in first", Code: http.StatusBadRequest})
		return
	}
	csrf, err := webRandomToken("mta_csrf_")
	if err != nil {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "session_creation_failed", Message: "Could not create browser session", Code: http.StatusServiceUnavailable})
		return
	}
	pair, err := h.db.CreateOrRecoverClerkMigrationSession(c.Request.Context(), user.ID, *user.ClerkID, "web", "Browser", successor)
	if errors.Is(err, database.ErrClerkIdentityUnknown) {
		h.clearPending(c)
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{Error: "unauthorized", Message: "This Clerk account is no longer linked", Code: http.StatusUnauthorized})
		return
	}
	if errors.Is(err, database.ErrIdentityOwnedByOther) {
		h.clearPending(c)
		c.JSON(http.StatusConflict, models.ErrorResponse{Error: "identity_conflict", Message: "Could not link this identity to the account", Code: http.StatusConflict})
		return
	}
	if err != nil {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "session_creation_failed", Message: "Could not create browser session", Code: http.StatusServiceUnavailable})
		return
	}
	h.setPair(c, pair)
	h.clearOnboardingAll(c)
	h.setCookie(c, middleware.WebCSRFCookie, csrf, webRefreshMaxAge, false, "/")
	c.JSON(http.StatusCreated, gin.H{"authenticated": true, "user_id": user.ID, "clerk_id": *user.ClerkID, "onboarding_required": user.OnboardingRequired, "access_expires_at": pair.AccessExpiresAt})
}

// PrepareBootstrap writes the refresh successor and CSRF secret before Clerk
// session exchange. Exact Origin is the signed-out request's CSRF boundary;
// the commit then requires the double-submit token too.
func (h *WebSessionHandler) PrepareBootstrap(c *gin.Context) {
	if !h.validOrigin(c) {
		c.JSON(http.StatusForbidden, models.ErrorResponse{Error: "origin_invalid", Message: "Use the Media Tools app to sign in", Code: http.StatusForbidden})
		return
	}
	csrf, err := webRandomToken("mta_csrf_")
	if err != nil {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not prepare browser sign-in", Code: http.StatusServiceUnavailable})
		return
	}
	if pending, err := c.Cookie(middleware.WebPendingCookie); err == nil && database.ValidFirstPartyRefreshToken(pending) {
		if err := h.revokeCookieSessions(c, middleware.WebRecoveryPendingCookie, middleware.WebOnboardingPendingCookie); err != nil {
			log.Printf("revoke interrupted recovery before Clerk bootstrap retry: %v", err)
			c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not prepare this browser for sign-in; retry", Code: http.StatusServiceUnavailable})
			return
		}
		h.clearRecoveryPending(c)
		h.clearOnboardingAll(c)
		h.setCookie(c, middleware.WebCSRFCookie, csrf, webRefreshMaxAge, false, "/")
		c.Header("Cache-Control", "no-store")
		c.Status(http.StatusNoContent)
		return
	}
	if err := h.revokeCookieSessions(c, middleware.WebRefreshCookie, middleware.WebRecoveryPendingCookie, middleware.WebOnboardingPendingCookie); err != nil {
		log.Printf("revoke browser session before Clerk bootstrap: %v", err)
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not prepare this browser for sign-in; retry", Code: http.StatusServiceUnavailable})
		return
	}
	successor, err := webRandomToken("mta_rt_")
	if err != nil {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not prepare browser sign-in", Code: http.StatusServiceUnavailable})
		return
	}
	h.setCookie(c, middleware.WebAccessCookie, "", -1, true, "/api/v1")
	h.setCookie(c, middleware.WebRefreshCookie, "", -1, true, "/api/v1/auth/web/session")
	h.setCookie(c, middleware.WebPendingCookie, successor, 24*60*60, true, "/api/v1/auth/web/session")
	h.clearRecoveryPending(c)
	h.clearOnboardingAll(c)
	h.setCookie(c, middleware.WebCSRFCookie, csrf, webRefreshMaxAge, false, "/")
	c.Header("Cache-Control", "no-store")
	c.Status(http.StatusNoContent)
}

func (h *WebSessionHandler) Status(c *gin.Context) {
	credential, err := c.Cookie(middleware.WebAccessCookie)
	if err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"authenticated": false})
		return
	}
	user, _, err := h.db.GetUserByFirstPartyAccessToken(c.Request.Context(), credential)
	if errors.Is(err, database.ErrSessionInvalid) {
		c.JSON(http.StatusUnauthorized, gin.H{"authenticated": false})
		return
	}
	if err != nil {
		log.Printf("load browser session status: %v", err)
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not check your session; retry", Code: http.StatusServiceUnavailable})
		return
	}
	c.Header("Cache-Control", "no-store")
	c.JSON(http.StatusOK, gin.H{"authenticated": true, "user_id": user.ID, "clerk_id": user.ClerkID, "onboarding_required": user.OnboardingRequired})
}

// Prepare journals the successor credential in an HttpOnly cookie before the
// refresh rotates server state. A lost refresh response can then retry with the
// same old/new pair without revoking the browser's session.
func (h *WebSessionHandler) Prepare(c *gin.Context) {
	if h.rejectCSRF(c) {
		return
	}
	if _, err := c.Cookie(middleware.WebRefreshCookie); err != nil {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{Error: "invalid_session", Message: "Sign in again to continue", Code: http.StatusUnauthorized})
		return
	}
	if pending, err := c.Cookie(middleware.WebPendingCookie); err == nil && pending != "" {
		c.Status(http.StatusNoContent)
		return
	}
	successor, err := webRandomToken("mta_rt_")
	if err != nil {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not prepare session renewal", Code: http.StatusServiceUnavailable})
		return
	}
	h.setCookie(c, middleware.WebPendingCookie, successor, 24*60*60, true, "/api/v1/auth/web/session")
	c.Header("Cache-Control", "no-store")
	c.Status(http.StatusNoContent)
}

func (h *WebSessionHandler) Refresh(c *gin.Context) {
	if h.rejectCSRF(c) {
		return
	}
	old, oldErr := c.Cookie(middleware.WebRefreshCookie)
	successor, nextErr := c.Cookie(middleware.WebPendingCookie)
	if oldErr != nil || nextErr != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "refresh_not_prepared", Message: "Prepare session renewal first", Code: http.StatusBadRequest})
		return
	}
	pair, err := h.db.RefreshFirstPartySessionWithSuccessor(c.Request.Context(), old, successor)
	switch {
	case err == nil:
		h.setPair(c, pair)
		c.JSON(http.StatusOK, gin.H{"user_id": pair.UserID, "access_expires_at": pair.AccessExpiresAt})
	case errors.Is(err, database.ErrInvalidSuccessorToken):
		h.clearPending(c)
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "invalid_request", Message: "Prepare session renewal again", Code: http.StatusBadRequest})
	case errors.Is(err, database.ErrSessionInvalid), errors.Is(err, database.ErrSessionReplay):
		h.clear(c)
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{Error: "invalid_session", Message: "Sign in again to continue", Code: http.StatusUnauthorized})
	default:
		log.Printf("refresh browser session: %v", err)
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not renew session; retry", Code: http.StatusServiceUnavailable})
	}
}

func (h *WebSessionHandler) Logout(c *gin.Context) {
	if h.rejectCSRF(c) {
		return
	}
	if refresh, err := c.Cookie(middleware.WebRefreshCookie); err == nil {
		if err := h.db.RevokeFirstPartySessionByRefreshToken(c.Request.Context(), refresh); err != nil && !errors.Is(err, database.ErrSessionInvalid) {
			log.Printf("revoke browser session on logout: %v", err)
			c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not sign out; please try again", Code: http.StatusServiceUnavailable})
			return
		}
	}
	// Lost refresh or recovery responses can leave the active credential in a
	// pending HttpOnly cookie. Revoke every exact credential before clearing.
	if err := h.revokeCookieSessions(c, middleware.WebPendingCookie, middleware.WebPasswordPendingCookie, middleware.WebRecoveryPendingCookie, middleware.WebOnboardingPendingCookie); err != nil {
		log.Printf("revoke pending browser session on logout: %v", err)
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not sign out; please try again", Code: http.StatusServiceUnavailable})
		return
	}
	h.clear(c)
	c.Header("Cache-Control", "no-store")
	c.Status(http.StatusNoContent)
}
