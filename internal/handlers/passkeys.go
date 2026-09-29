package handlers

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"
	"github.com/google/uuid"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

const passkeyRPID = "media.shimizu-technology.com"
const passkeyOrigin = "https://media.shimizu-technology.com"

// NewPasskeyAuthenticator pins every ceremony to the production domain. Other
// origins, including Android APK origins, need separately verified identity
// metadata before they can be accepted.
func NewPasskeyAuthenticator() (*webauthn.WebAuthn, error) {
	return webauthn.New(&webauthn.Config{
		RPDisplayName: "Media Tools",
		RPID:          passkeyRPID,
		RPOrigins:     []string{passkeyOrigin},
		AuthenticatorSelection: protocol.AuthenticatorSelection{
			UserVerification: protocol.VerificationRequired,
		},
		Timeouts: webauthn.TimeoutsConfig{
			Registration: webauthn.TimeoutConfig{Enforce: true, Timeout: 5 * time.Minute},
			Login:        webauthn.TimeoutConfig{Enforce: true, Timeout: 5 * time.Minute},
		},
	})
}

type passkeyAccount struct {
	user        *models.User
	handle      []byte
	credentials []webauthn.Credential
	revisions   map[string]int64
}

func (u *passkeyAccount) WebAuthnID() []byte   { return u.handle }
func (u *passkeyAccount) WebAuthnName() string { return u.user.Email }
func (u *passkeyAccount) WebAuthnDisplayName() string {
	if strings.TrimSpace(u.user.Name) != "" {
		return u.user.Name
	}
	return u.user.Email
}
func (u *passkeyAccount) WebAuthnCredentials() []webauthn.Credential { return u.credentials }

func (h *Handler) passkeyAccount(c *gin.Context, user *models.User) (*passkeyAccount, error) {
	parsed, err := uuid.Parse(user.ID)
	if err != nil {
		return nil, fmt.Errorf("invalid application user ID: %w", err)
	}
	stored, err := h.DB.ListPasskeysForUser(c.Request.Context(), user.ID)
	if err != nil {
		return nil, err
	}
	account := &passkeyAccount{
		user:        user,
		handle:      parsed[:],
		credentials: make([]webauthn.Credential, 0, len(stored)),
		revisions:   make(map[string]int64, len(stored)),
	}
	for _, item := range stored {
		account.credentials = append(account.credentials, item.Credential)
		account.revisions[string(item.Credential.ID)] = item.Revision
	}
	return account, nil
}

func passkeyError(c *gin.Context, status int, code, message string) {
	c.Header("Cache-Control", "no-store")
	c.JSON(status, models.ErrorResponse{Error: code, Message: message, Code: status})
}

func (h *Handler) BeginPasskeyRegistration(c *gin.Context) {
	user, binding := middleware.GetUser(c), middleware.AuthSessionBinding(c)
	if user == nil || binding == "" {
		passkeyError(c, http.StatusUnauthorized, "unauthorized", "A signed-in device session is required")
		return
	}
	account, err := h.passkeyAccount(c, user)
	if err != nil {
		passkeyError(c, http.StatusServiceUnavailable, "authentication_unavailable", "Could not prepare passkey registration")
		return
	}
	creation, session, err := h.Passkeys.BeginRegistration(account,
		webauthn.WithResidentKeyRequirement(protocol.ResidentKeyRequirementRequired),
		webauthn.WithExclusions(webauthn.Credentials(account.credentials).CredentialDescriptors()),
	)
	if err != nil {
		passkeyError(c, http.StatusServiceUnavailable, "authentication_unavailable", "Could not prepare passkey registration")
		return
	}
	id, err := h.DB.CreatePasskeyCeremony(c.Request.Context(), "register", user.ID, binding, session)
	if err != nil {
		passkeyError(c, http.StatusServiceUnavailable, "authentication_unavailable", "Could not save passkey challenge")
		return
	}
	c.Header("Cache-Control", "no-store")
	c.JSON(http.StatusOK, gin.H{"ceremony_id": id, "options": creation.Response})
}

type passkeyFinishRequest struct {
	CeremonyID string          `json:"ceremony_id" binding:"required"`
	Credential json.RawMessage `json:"credential" binding:"required"`
}

func passkeyCredentialRequest(c *gin.Context, encoded json.RawMessage) *http.Request {
	request := c.Request.Clone(c.Request.Context())
	request.Body = io.NopCloser(bytes.NewReader(encoded))
	request.ContentLength = int64(len(encoded))
	request.Header.Set("Content-Type", "application/json")
	return request
}

func (h *Handler) FinishPasskeyRegistration(c *gin.Context) {
	user, binding := middleware.GetUser(c), middleware.AuthSessionBinding(c)
	if user == nil || binding == "" {
		passkeyError(c, http.StatusUnauthorized, "unauthorized", "A signed-in device session is required")
		return
	}
	var req passkeyFinishRequest
	if err := c.ShouldBindJSON(&req); err != nil || uuid.Validate(req.CeremonyID) != nil || len(req.Credential) == 0 {
		passkeyError(c, http.StatusBadRequest, "invalid_request", "Ceremony ID and passkey response are required")
		return
	}
	session, err := h.DB.ConsumePasskeyCeremony(c.Request.Context(), req.CeremonyID, "register", user.ID, binding)
	if errors.Is(err, database.ErrPasskeyCeremonyInvalid) {
		passkeyError(c, http.StatusUnauthorized, "invalid_challenge", "Passkey challenge expired or was already used")
		return
	}
	if err != nil {
		passkeyError(c, http.StatusServiceUnavailable, "authentication_unavailable", "Could not verify passkey challenge")
		return
	}
	account, err := h.passkeyAccount(c, user)
	if err != nil {
		passkeyError(c, http.StatusServiceUnavailable, "authentication_unavailable", "Could not load passkey account")
		return
	}
	credential, err := h.Passkeys.FinishRegistration(account, *session, passkeyCredentialRequest(c, req.Credential))
	if err != nil {
		passkeyError(c, http.StatusUnauthorized, "invalid_passkey", "Passkey registration could not be verified")
		return
	}
	if err := h.DB.AddPasskeyCredential(c.Request.Context(), user.ID, credential); err != nil {
		if errors.Is(err, database.ErrPasskeyCredentialExists) {
			passkeyError(c, http.StatusConflict, "passkey_exists", "This passkey is already registered")
		} else {
			passkeyError(c, http.StatusServiceUnavailable, "authentication_unavailable", "Could not save passkey")
		}
		return
	}
	c.Header("Cache-Control", "no-store")
	c.JSON(http.StatusCreated, gin.H{"credential_id": base64.RawURLEncoding.EncodeToString(credential.ID)})
}

func (h *Handler) BeginPasskeyLogin(c *gin.Context) {
	assertion, session, err := h.Passkeys.BeginDiscoverableLogin(webauthn.WithUserVerification(protocol.VerificationRequired))
	if err != nil {
		passkeyError(c, http.StatusServiceUnavailable, "authentication_unavailable", "Could not prepare passkey sign-in")
		return
	}
	id, err := h.DB.CreatePasskeyCeremony(c.Request.Context(), "login", "", "", session)
	if err != nil {
		passkeyError(c, http.StatusServiceUnavailable, "authentication_unavailable", "Could not save passkey challenge")
		return
	}
	c.Header("Cache-Control", "no-store")
	c.JSON(http.StatusOK, gin.H{"ceremony_id": id, "options": assertion.Response})
}

type passkeyLoginFinishRequest struct {
	passkeyFinishRequest
	ClientType string `json:"client_type" binding:"required"`
	DeviceName string `json:"device_name"`
}

func (h *Handler) FinishPasskeyLogin(c *gin.Context) {
	var req passkeyLoginFinishRequest
	if err := c.ShouldBindJSON(&req); err != nil || uuid.Validate(req.CeremonyID) != nil || len(req.Credential) == 0 ||
		(req.ClientType != "web" && req.ClientType != "ios" && req.ClientType != "android") || len(strings.TrimSpace(req.DeviceName)) > 80 {
		passkeyError(c, http.StatusBadRequest, "invalid_request", "Valid ceremony, passkey response, and client type are required")
		return
	}
	session, err := h.DB.ConsumePasskeyCeremony(c.Request.Context(), req.CeremonyID, "login", "", "")
	if errors.Is(err, database.ErrPasskeyCeremonyInvalid) {
		passkeyError(c, http.StatusUnauthorized, "invalid_challenge", "Passkey challenge expired or was already used")
		return
	}
	if err != nil {
		passkeyError(c, http.StatusServiceUnavailable, "authentication_unavailable", "Could not verify passkey challenge")
		return
	}
	lookup := func(credentialID, userHandle []byte) (webauthn.User, error) {
		userID, err := h.DB.GetPasskeyCredentialOwner(c.Request.Context(), credentialID)
		if err != nil {
			return nil, err
		}
		parsed, err := uuid.FromBytes(userHandle)
		if err != nil || parsed.String() != userID {
			return nil, fmt.Errorf("passkey handle does not match credential owner")
		}
		user, err := h.DB.GetUserByID(c.Request.Context(), userID)
		if err != nil {
			return nil, err
		}
		return h.passkeyAccount(c, user)
	}
	verified, credential, err := h.Passkeys.FinishPasskeyLogin(lookup, *session, passkeyCredentialRequest(c, req.Credential))
	if err != nil {
		passkeyError(c, http.StatusUnauthorized, "invalid_passkey", "Passkey sign-in could not be verified")
		return
	}
	account, ok := verified.(*passkeyAccount)
	if !ok {
		passkeyError(c, http.StatusServiceUnavailable, "authentication_unavailable", "Could not complete passkey sign-in")
		return
	}
	revision, ok := account.revisions[string(credential.ID)]
	if !ok {
		passkeyError(c, http.StatusUnauthorized, "invalid_passkey", "Passkey sign-in could not be verified")
		return
	}
	if err := h.DB.UpdatePasskeyCredential(c.Request.Context(), account.user.ID, credential, revision); err != nil {
		passkeyError(c, http.StatusServiceUnavailable, "authentication_unavailable", "Could not update passkey state; try again")
		return
	}
	pair, err := h.DB.CreateFirstPartySession(c.Request.Context(), account.user.ID, req.ClientType, req.DeviceName)
	if err != nil {
		passkeyError(c, http.StatusServiceUnavailable, "authentication_unavailable", "Could not create device session")
		return
	}
	c.Header("Cache-Control", "no-store")
	c.JSON(http.StatusCreated, pair)
}
