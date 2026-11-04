package handlers

import (
	"context"
	"errors"
	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"net/http"
	"net/mail"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	accountservice "github.com/Shimizu-Technology/media-tools-api/internal/services/account"
	emailservice "github.com/Shimizu-Technology/media-tools-api/internal/services/email"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

type emailProofRequest struct {
	Email           string `json:"email"`
	Password        string `json:"password"`
	CurrentPassword string `json:"current_password"`
	Name            string `json:"name"`
	Code            string `json:"code"`
}

func validEmail(email string) bool {
	if len(email) > 255 || !utf8.ValidString(email) {
		return false
	}
	parsed, err := mail.ParseAddress(email)
	return err == nil && parsed.Address == email && strings.Contains(email, "@")
}
func authError(c *gin.Context, status int, code, message string) {
	c.Header("Cache-Control", "no-store")
	c.JSON(status, models.ErrorResponse{Error: code, Message: message, Code: status})
}
func acceptedEmail(c *gin.Context) {
	c.Header("Cache-Control", "no-store")
	c.JSON(http.StatusAccepted, gin.H{"message": "If this request is eligible, an email will arrive shortly"})
}
func (h *Handler) newPassword(c *gin.Context, raw string) (string, bool) {
	password, err := accountservice.NormalizeNewPassword(raw)
	if err != nil {
		authError(c, http.StatusBadRequest, "weak_password", "Use a password of 12 to 128 characters")
		return "", false
	}
	if h.Pwned != nil && h.Pwned.Compromised(c.Request.Context(), password) {
		authError(c, http.StatusBadRequest, "password_compromised", "Choose a password that has not appeared in a data breach")
		return "", false
	}
	hash, err := h.Passwords.Hash(c.Request.Context(), password)
	if err != nil {
		authError(c, http.StatusServiceUnavailable, "authentication_unavailable", "Try again shortly")
		return "", false
	}
	return hash, true
}

// requireCurrentPassword returns the exact verified snapshot, not just a bool.
// The mutation checks it again while holding the account lock. A passwordless
// deployed account can still enroll its first password with its existing session.
func (h *Handler) requireCurrentPassword(c *gin.Context, userID, raw string) (string, bool) {
	credential, err := h.DB.PasswordCredentialForUser(c.Request.Context(), userID)
	if errors.Is(err, database.ErrPasswordCredentialInvalid) {
		return "", true
	}
	if err != nil || h.Passwords == nil {
		authError(c, http.StatusServiceUnavailable, "authentication_unavailable", "Try again shortly")
		return "", false
	}
	if len(raw) > 1024 || !utf8.ValidString(raw) {
		authError(c, http.StatusUnauthorized, "current_password_required", "Enter your current password")
		return "", false
	}
	verified, err := h.Passwords.Verify(c.Request.Context(), credential.PasswordHash, raw)
	if err != nil {
		authError(c, http.StatusServiceUnavailable, "authentication_unavailable", "Try again shortly")
		return "", false
	}
	if !verified.Valid {
		authError(c, http.StatusUnauthorized, "current_password_required", "Enter your current password")
		return "", false
	}
	return credential.PasswordHash, true
}

func (h *Handler) beginEmailProof(c *gin.Context, purpose string) {
	if purpose == "signup" && !h.PublicSignupEnabled {
		authError(c, http.StatusForbidden, "signup_disabled", "Sign-up is not available yet")
		return
	}
	var req emailProofRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		authError(c, http.StatusBadRequest, "invalid_request", "Enter a valid email")
		return
	}
	req.Email = database.NormalizeLoginEmail(req.Email)
	if !validEmail(req.Email) || len(req.Name) > 200 || !utf8.ValidString(req.Name) {
		authError(c, http.StatusBadRequest, "invalid_request", "Enter a valid email and name")
		return
	}
	ch := database.EmailChallenge{ID: uuid.NewString(), Purpose: purpose, Email: req.Email, Name: strings.TrimSpace(req.Name)}
	if purpose == "signup" {
		hash, ok := h.newPassword(c, req.Password)
		if !ok {
			return
		}
		ch.PasswordHash = hash
	}
	if purpose == "verify" || purpose == "email_change" {
		user := firstPartyAccount(c)
		if user == nil {
			return
		}
		ch.UserID = &user.ID
		if purpose == "verify" {
			if database.NormalizeLoginEmail(user.Email) != req.Email {
				authError(c, http.StatusBadRequest, "invalid_request", "Use your account email")
				return
			}
		}
		if purpose == "email_change" {
			snapshot, ok := h.requireCurrentPassword(c, user.ID, req.CurrentPassword)
			if !ok {
				return
			}
			if snapshot == "" {
				authError(c, http.StatusConflict, "password_required", "Set a password before changing email")
				return
			}
			ch.CredentialSnapshot = snapshot
		}
	}
	code, err := emailservice.NewCode()
	if err != nil {
		authError(c, http.StatusServiceUnavailable, "authentication_unavailable", "Try again shortly")
		return
	}
	ch.CodeHash = h.Email.CodeHash(ch.ID, code)
	sealed, err := h.Email.Seal(emailservice.CodeMessage(req.Email, code, purpose))
	if err != nil {
		authError(c, http.StatusServiceUnavailable, "authentication_unavailable", "Try again shortly")
		return
	}
	_, err = h.DB.IssueEmailChallenge(c.Request.Context(), ch, sealed)
	if err != nil {
		authError(c, http.StatusServiceUnavailable, "authentication_unavailable", "Try again shortly")
		return
	}
	if h.Worker != nil {
		h.Worker.Wake()
	}
	acceptedEmail(c)
}
func (h *Handler) Signup(c *gin.Context)                 { h.beginEmailProof(c, "signup") }
func (h *Handler) ForgotPassword(c *gin.Context)         { h.beginEmailProof(c, "reset") }
func (h *Handler) BeginEmailChange(c *gin.Context)       { h.beginEmailProof(c, "email_change") }
func (h *Handler) BeginEmailVerification(c *gin.Context) { h.beginEmailProof(c, "verify") }

func (h *Handler) finishEmailProof(c *gin.Context, purpose string) {
	if purpose == "signup" && !h.PublicSignupEnabled {
		authError(c, http.StatusForbidden, "signup_disabled", "Sign-up is not available yet")
		return
	}
	var req emailProofRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		authError(c, http.StatusBadRequest, "invalid_request", "Enter the email and six-digit code")
		return
	}
	req.Email = database.NormalizeLoginEmail(req.Email)
	if !validEmail(req.Email) || len(req.Code) != 6 || strings.IndexFunc(req.Code, func(r rune) bool { return r < '0' || r > '9' }) >= 0 {
		authError(c, http.StatusBadRequest, "invalid_code", "Code is invalid or expired")
		return
	}
	if purpose == "email_change" || purpose == "verify" {
		user := firstPartyAccount(c)
		if user == nil {
			return
		}
		// A proof is never transferable to another authenticated account.
		var owned bool
		err := h.DB.GetContext(c.Request.Context(), &owned, `SELECT EXISTS(SELECT 1 FROM auth_email_challenges WHERE purpose=$1 AND email=$2 AND user_id=$3)`, purpose, req.Email, user.ID)
		if err != nil {
			authError(c, http.StatusServiceUnavailable, "authentication_unavailable", "Try again shortly")
			return
		}
		if !owned {
			authError(c, http.StatusBadRequest, "invalid_code", "Code is invalid or expired")
			return
		}
	}
	hash := ""
	if purpose == "reset" {
		var ok bool
		hash, ok = h.newPassword(c, req.Password)
		if !ok {
			return
		}
	}
	err := h.DB.CompleteEmailChallenge(c.Request.Context(), purpose, req.Email, req.Code, hash, h.Email.CodeHash, func(to, action string) (string, error) { return h.Email.Seal(emailservice.Notice(to, action)) })
	if errors.Is(err, database.ErrEmailCodeInvalid) {
		authError(c, http.StatusBadRequest, "invalid_code", "Code is invalid or expired")
		return
	}
	if err != nil {
		authError(c, http.StatusServiceUnavailable, "authentication_unavailable", "Try again shortly")
		return
	}
	if h.Worker != nil {
		h.Worker.Wake()
	}
	c.Header("Cache-Control", "no-store")
	c.JSON(http.StatusOK, gin.H{"verified": true, "sign_in_required": purpose != "verify"})
}
func (h *Handler) VerifySignup(c *gin.Context)            { h.finishEmailProof(c, "signup") }
func (h *Handler) ResetPassword(c *gin.Context)           { h.finishEmailProof(c, "reset") }
func (h *Handler) FinishEmailChange(c *gin.Context)       { h.finishEmailProof(c, "email_change") }
func (h *Handler) FinishEmailVerification(c *gin.Context) { h.finishEmailProof(c, "verify") }

func (h *Handler) rejectPassword(c *gin.Context, email string) {
	if h.Email == nil {
		passwordCredentialsRejected(c)
		return
	}
	allowed, err := h.DB.RecordAuthFailure(c.Request.Context(), h.Email.CodeHash("login-failure", database.NormalizeLoginEmail(email)))
	if err != nil {
		authError(c, http.StatusServiceUnavailable, "authentication_unavailable", "Try again shortly")
		return
	}
	_ = h.DB.RecordAuthEvent(c.Request.Context(), "", "password_login_failed")
	if !allowed {
		c.Header("Retry-After", "900")
		authError(c, http.StatusTooManyRequests, "rate_limit_exceeded", "Too many unsuccessful attempts; use your correct password or try again later")
		return
	}
	passwordCredentialsRejected(c)
}

// PurgeAuthTraffic limits cleanup to one caller per process every hour. The
// database performs idempotent deletes, so overlapping instances are harmless.
func (h *Handler) PurgeAuthTraffic() gin.HandlerFunc {
	return func(c *gin.Context) {
		now := time.Now().Unix()
		previous := h.lastAuthPurge.Load()
		if now-previous > 3600 && h.lastAuthPurge.CompareAndSwap(previous, now) {
			ctx, cancel := context.WithTimeout(c.Request.Context(), 5*time.Second)
			_ = h.DB.PurgeAuth(ctx)
			cancel()
		}
		c.Next()
	}
}

// AuthAudit stores route/outcome only. Request bodies, URLs, addresses, codes,
// cookies and bearer credentials must never enter this table or its logs.
func (h *Handler) AuthAudit() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Next()
		if c.Request.Method == http.MethodGet || !strings.HasPrefix(c.FullPath(), "/api/v1/auth/") {
			return
		}
		userID := ""
		if user := middleware.GetUser(c); user != nil {
			userID = user.ID
		}
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		event := c.Request.Method + " " + c.FullPath() + " " + strconv.Itoa(c.Writer.Status())
		_ = h.DB.RecordAuthEvent(ctx, userID, event)
	}
}
