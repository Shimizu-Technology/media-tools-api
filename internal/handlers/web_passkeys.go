package handlers

import (
	"errors"
	"log"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"
	"github.com/google/uuid"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

const webPasskeyDeviceName = "Browser"

// BeginPasskeyLogin starts a discoverable-credential ceremony for the web app.
// The exact page Origin is required because a signed-out browser does not have
// a CSRF secret yet. The endpoint installs both that secret and a server-blind
// refresh successor before the assertion can be submitted.
func (h *WebSessionHandler) BeginPasskeyLogin(c *gin.Context) {
	if !h.validOrigin(c) {
		c.JSON(http.StatusForbidden, models.ErrorResponse{Error: "origin_invalid", Message: "Use the Media Tools app to sign in", Code: http.StatusForbidden})
		return
	}
	if h.auth == nil || h.auth.Passkeys == nil {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Passkey sign-in is unavailable", Code: http.StatusServiceUnavailable})
		return
	}

	csrf, err := webRandomToken("mta_csrf_")
	if err != nil {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not prepare passkey sign-in", Code: http.StatusServiceUnavailable})
		return
	}
	successor, err := webRandomToken("mta_rt_")
	if err != nil {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not prepare passkey sign-in", Code: http.StatusServiceUnavailable})
		return
	}
	// Starting a new sign-in replaces any session already stored in this
	// browser. Revoke both possible refresh credentials before issuing another
	// year-long session so an account switch cannot leave an orphaned session.
	// This happens before persisting a ceremony, so a revocation outage does not
	// leave an unused challenge behind.
	if err := h.revokeStoredSessions(c); err != nil {
		log.Printf("revoke browser session before passkey sign-in: %v", err)
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not prepare this browser for sign-in; retry", Code: http.StatusServiceUnavailable})
		return
	}
	assertion, session, err := h.auth.Passkeys.BeginDiscoverableLogin(webauthn.WithUserVerification(protocol.VerificationRequired))
	if err != nil {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not prepare passkey sign-in", Code: http.StatusServiceUnavailable})
		return
	}
	ceremonyID, err := h.db.CreatePasskeyCeremony(c.Request.Context(), "login", "", "", session)
	if err != nil {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not save passkey challenge", Code: http.StatusServiceUnavailable})
		return
	}
	h.setCookie(c, middleware.WebAccessCookie, "", -1, true, "/api/v1")
	h.setCookie(c, middleware.WebRefreshCookie, "", -1, true, "/api/v1/auth/web/session")
	h.setCookie(c, middleware.WebPendingCookie, successor, 24*60*60, true, "/api/v1/auth/web/session")
	h.clearRecoveryPending(c)
	h.clearOnboardingAll(c)
	h.setCookie(c, middleware.WebCSRFCookie, csrf, webRefreshMaxAge, false, "/")
	c.Header("Cache-Control", "no-store")
	c.JSON(http.StatusOK, gin.H{"ceremony_id": ceremonyID, "options": assertion.Response})
}

func (h *WebSessionHandler) revokeStoredSessions(c *gin.Context) error {
	return h.revokeCookieSessions(c, middleware.WebRefreshCookie, middleware.WebPendingCookie, middleware.WebRecoveryPendingCookie, middleware.WebOnboardingPendingCookie)
}

func (h *WebSessionHandler) revokeCookieSessions(c *gin.Context, names ...string) error {
	seen := make(map[string]struct{}, len(names))
	for _, name := range names {
		credential, err := c.Cookie(name)
		if err != nil || credential == "" {
			continue
		}
		if _, duplicate := seen[credential]; duplicate {
			continue
		}
		seen[credential] = struct{}{}
		if err := h.db.RevokeFirstPartySessionByRefreshToken(c.Request.Context(), credential); err != nil && !errors.Is(err, database.ErrSessionInvalid) {
			return err
		}
	}
	return nil
}

// FinishPasskeyLogin verifies the assertion and writes the resulting tokens
// only to host-only HttpOnly cookies. Its body deliberately contains metadata,
// never credentials. The pending cookie lets the same ceremony recover an
// already-created session when the first response was lost.
func (h *WebSessionHandler) FinishPasskeyLogin(c *gin.Context) {
	if h.rejectCSRF(c) {
		return
	}
	if h.auth == nil || h.auth.Passkeys == nil {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Passkey sign-in is unavailable", Code: http.StatusServiceUnavailable})
		return
	}
	var req passkeyFinishRequest
	if err := c.ShouldBindJSON(&req); err != nil || uuid.Validate(req.CeremonyID) != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "invalid_request", Message: "A valid ceremony ID is required", Code: http.StatusBadRequest})
		return
	}
	successor, err := c.Cookie(middleware.WebPendingCookie)
	if err != nil || !database.ValidFirstPartyRefreshToken(successor) {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "sign_in_not_prepared", Message: "Start passkey sign-in again", Code: http.StatusBadRequest})
		return
	}
	csrf, err := webRandomToken("mta_csrf_")
	if err != nil {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not complete passkey sign-in", Code: http.StatusServiceUnavailable})
		return
	}

	pair, err := h.db.RecoverPasskeyLogin(c.Request.Context(), req.CeremonyID, successor)
	if err == nil {
		h.finishWebPasskeySession(c, pair, csrf)
		return
	}
	if !errors.Is(err, database.ErrPasskeyCeremonyInvalid) {
		log.Printf("recover browser passkey sign-in: %v", err)
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not recover passkey sign-in", Code: http.StatusServiceUnavailable})
		return
	}
	if len(req.Credential) == 0 {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{Error: "invalid_challenge", Message: "Passkey challenge expired or was already used", Code: http.StatusUnauthorized})
		return
	}

	session, err := h.db.ConsumePasskeyCeremony(c.Request.Context(), req.CeremonyID, "login", "", "")
	if errors.Is(err, database.ErrPasskeyCeremonyInvalid) {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{Error: "invalid_challenge", Message: "Passkey challenge expired or was already used", Code: http.StatusUnauthorized})
		return
	}
	if err != nil {
		log.Printf("consume browser passkey ceremony: %v", err)
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not verify passkey challenge", Code: http.StatusServiceUnavailable})
		return
	}
	lookup := func(credentialID, userHandle []byte) (webauthn.User, error) {
		userID, err := h.db.GetPasskeyCredentialOwner(c.Request.Context(), credentialID)
		if err != nil {
			return nil, err
		}
		parsed, err := uuid.FromBytes(userHandle)
		if err != nil || parsed.String() != userID {
			return nil, errors.New("passkey handle does not match credential owner")
		}
		user, err := h.db.GetUserByID(c.Request.Context(), userID)
		if err != nil {
			return nil, err
		}
		return h.auth.passkeyAccount(c, user)
	}
	verified, credential, err := h.auth.Passkeys.FinishPasskeyLogin(lookup, *session, passkeyCredentialRequest(c, req.Credential))
	if err != nil {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{Error: "invalid_passkey", Message: "Passkey sign-in could not be verified", Code: http.StatusUnauthorized})
		return
	}
	account, ok := verified.(*passkeyAccount)
	if !ok {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not complete passkey sign-in", Code: http.StatusServiceUnavailable})
		return
	}
	revision, ok := account.revisions[string(credential.ID)]
	if !ok {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{Error: "invalid_passkey", Message: "Passkey sign-in could not be verified", Code: http.StatusUnauthorized})
		return
	}
	pair, err = h.db.CompletePasskeyLogin(
		c.Request.Context(), req.CeremonyID, account.user.ID,
		credential, revision, "web", webPasskeyDeviceName, successor,
	)
	if err != nil {
		if errors.Is(err, database.ErrPasskeyCeremonyInvalid) {
			c.JSON(http.StatusUnauthorized, models.ErrorResponse{Error: "invalid_challenge", Message: "Passkey challenge expired or was already used", Code: http.StatusUnauthorized})
			return
		}
		log.Printf("complete browser passkey sign-in: %v", err)
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not create browser session", Code: http.StatusServiceUnavailable})
		return
	}
	h.finishWebPasskeySession(c, pair, csrf)
}

func (h *WebSessionHandler) finishWebPasskeySession(c *gin.Context, pair *database.AuthTokenPair, csrf string) {
	h.setPair(c, pair)
	h.clearOnboardingAll(c)
	h.setCookie(c, middleware.WebCSRFCookie, csrf, webRefreshMaxAge, false, "/")
	c.Header("Cache-Control", "no-store")
	c.JSON(http.StatusCreated, gin.H{
		"user_id":           pair.UserID,
		"access_expires_at": pair.AccessExpiresAt.UTC().Format(time.RFC3339Nano),
	})
}
