package handlers

import (
	"context"
	"errors"
	emailservice "github.com/Shimizu-Technology/media-tools-api/internal/services/email"
	"log"
	"net/http"
	"strings"
	"unicode/utf8"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	accountservice "github.com/Shimizu-Technology/media-tools-api/internal/services/account"
)

var errPasswordRejected = errors.New("password credentials rejected")

type passwordLoginRequest struct {
	Email            string `json:"email" binding:"required"`
	Password         string `json:"password" binding:"required"`
	ClientType       string `json:"client_type" binding:"required"`
	DeviceName       string `json:"device_name"`
	NextRefreshToken string `json:"next_refresh_token" binding:"required"`
}

func passwordCredentialsRejected(c *gin.Context) {
	c.Header("Cache-Control", "no-store")
	c.JSON(http.StatusUnauthorized, models.ErrorResponse{
		Error: "invalid_credentials", Message: "Email or password is incorrect", Code: http.StatusUnauthorized,
	})
}

func validPasswordLoginShape(req passwordLoginRequest) bool {
	email := database.NormalizeLoginEmail(req.Email)
	return email != "" && utf8.ValidString(email) && len(email) <= 255 &&
		len(req.Password) > 0 && len(req.Password) <= 1024 && utf8.ValidString(req.Password) &&
		(req.ClientType == "ios" || req.ClientType == "android") &&
		len(strings.TrimSpace(req.DeviceName)) <= 80 &&
		database.ValidFirstPartyRefreshToken(req.NextRefreshToken)
}

// LoginWithPassword verifies a first-party credential and issues the same
// opaque, revocable session used by passkeys and recovery codes.
func (h *Handler) LoginWithPassword(c *gin.Context) {
	var req passwordLoginRequest
	if err := c.ShouldBindJSON(&req); err != nil || !validPasswordLoginShape(req) {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "invalid_request", Message: "Valid email, password, device, and saved refresh credential are required", Code: http.StatusBadRequest})
		return
	}
	pair, err := h.createPasswordSession(c.Request.Context(), req.Email, req.Password, req.ClientType, req.DeviceName, req.NextRefreshToken, nil)
	if errors.Is(err, errPasswordRejected) {
		h.rejectPassword(c, req.Email)
		return
	}
	if errors.Is(err, database.ErrInvalidSuccessorToken) || errors.Is(err, database.ErrSessionInvalid) {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "invalid_request", Message: "Could not create a device session with this saved credential", Code: http.StatusBadRequest})
		return
	}
	if err != nil {
		log.Printf("create password session: %v", err)
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not sign in right now", Code: http.StatusServiceUnavailable})
		return
	}
	c.Header("Cache-Control", "no-store")
	c.JSON(http.StatusCreated, pair)
}

func (h *Handler) createPasswordSession(ctx context.Context, email, rawPassword, clientType, deviceName, successor string, existingCredentials []string) (*database.AuthTokenPair, error) {
	password, ok := accountservice.NormalizePasswordForLogin(rawPassword)
	if !ok {
		return nil, errPasswordRejected
	}
	credential, err := h.DB.GetPasswordCredentialByEmail(ctx, email)
	if errors.Is(err, database.ErrPasswordCredentialInvalid) {
		if dummyErr := h.Passwords.VerifyDummy(ctx, password); dummyErr != nil {
			return nil, dummyErr
		}
		return nil, errPasswordRejected
	}
	if err != nil {
		return nil, err
	}
	verified, err := h.Passwords.Verify(ctx, credential.PasswordHash, password)
	if err != nil {
		return nil, err
	}
	if !verified.Valid {
		if failureErr := h.DB.RecordPasswordFailure(ctx, credential.UserID, credential.PasswordHash); failureErr != nil {
			log.Printf("record password failure for user %s: %v", credential.UserID, failureErr)
		}
		return nil, errPasswordRejected
	}
	replacementHash := ""
	if verified.NeedsRehash {
		replacementHash, err = h.Passwords.Hash(ctx, accountservice.NormalizeVerifiedPassword(password))
		if err != nil {
			return nil, err
		}
	}
	var pair *database.AuthTokenPair
	if clientType == "web" {
		pair, err = h.DB.CreateOrRecoverWebPasswordSession(
			ctx, credential.UserID, credential.PasswordHash, replacementHash,
			successor, existingCredentials,
		)
	} else {
		pair, err = h.DB.CreateOrRecoverPasswordSession(
			ctx, credential.UserID, credential.PasswordHash, replacementHash,
			clientType, strings.TrimSpace(deviceName), successor,
		)
	}
	if errors.Is(err, database.ErrPasswordCredentialInvalid) || errors.Is(err, database.ErrPasswordCredentialChanged) || errors.Is(err, database.ErrPasswordCredentialLocked) {
		return nil, errPasswordRejected
	}
	if err == nil {
		_ = h.DB.RecordAuthEvent(ctx, credential.UserID, "password_login_succeeded")
	}
	return pair, err
}

func (h *Handler) PasswordStatus(c *gin.Context) {
	user := firstPartyAccount(c)
	if user == nil {
		return
	}
	status, err := h.DB.GetPasswordStatus(c.Request.Context(), user.ID)
	if err != nil {
		log.Printf("load password status for user %s: %v", user.ID, err)
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not check password status", Code: http.StatusServiceUnavailable})
		return
	}
	if h.Worker != nil {
		h.Worker.Wake()
	}
	c.Header("Cache-Control", "no-store")
	c.JSON(http.StatusOK, status)
}

type setPasswordRequest struct {
	Password        string `json:"password" binding:"required"`
	CurrentPassword string `json:"current_password"`
}

func (h *Handler) SetPassword(c *gin.Context) {
	user := firstPartyAccount(c)
	if user == nil {
		return
	}
	sessionID := strings.TrimPrefix(middleware.AuthSessionBinding(c), "first-party:")
	if sessionID == "" {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{Error: "first_party_session_required", Message: "A signed-in first-party device session is required", Code: http.StatusUnauthorized})
		return
	}
	var req setPasswordRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{Error: "invalid_request", Message: "A new password is required", Code: http.StatusBadRequest})
		return
	}
	snapshot, ok := h.requireCurrentPassword(c, user.ID, req.CurrentPassword)
	if !ok {
		return
	}
	if snapshot == "" {
		verified, verifyErr := h.DB.EmailVerified(c.Request.Context(), user.ID)
		if verifyErr != nil {
			authError(c, http.StatusServiceUnavailable, "authentication_unavailable", "Try again shortly")
			return
		}
		if !verified {
			authError(c, http.StatusForbidden, "email_verification_required", "Verify your email or use forgot password before setting a password")
			return
		}
	}
	hash, ok := h.newPassword(c, req.Password)
	if !ok {
		return
	}
	notice := ""
	if h.Email != nil {
		var err error
		notice, err = h.Email.Seal(emailservice.Notice(user.Email, "password"))
		if err != nil {
			authError(c, 503, "authentication_unavailable", "Try again shortly")
			return
		}
	}
	status, err := h.DB.SetPasswordCredential(c.Request.Context(), user.ID, sessionID, hash, database.PasswordChange{Snapshot: snapshot, Notice: notice})
	if errors.Is(err, database.ErrPasswordCredentialChanged) {
		authError(c, 409, "credential_changed", "Your password changed; sign in again")
		return
	}
	if errors.Is(err, database.ErrSessionInvalid) {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{Error: "invalid_session", Message: "Sign in again to change the password", Code: http.StatusUnauthorized})
		return
	}
	if err != nil {
		log.Printf("set password for user %s: %v", user.ID, err)
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{Error: "authentication_unavailable", Message: "Could not save the password", Code: http.StatusServiceUnavailable})
		return
	}
	if h.Worker != nil {
		h.Worker.Wake()
	}
	c.Header("Cache-Control", "no-store")
	c.JSON(http.StatusOK, status)
}
