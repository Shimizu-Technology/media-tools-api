// auth.go handles user authentication HTTP endpoints (MTA-20).
package handlers

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

// Register creates a new user account.
// POST /api/v1/auth/register

// Login authenticates a user and returns a JWT token.
// POST /api/v1/auth/login

// GetMe returns the current authenticated user.
// GET /api/v1/auth/me
func (h *Handler) GetMe(c *gin.Context) {
	user := middleware.GetUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{
			Error:   "unauthorized",
			Message: "Not authenticated",
			Code:    http.StatusUnauthorized,
		})
		return
	}

	verified := false
	if h.Email != nil {
		var err error
		verified, err = h.DB.EmailVerified(c.Request.Context(), user.ID)
		if err != nil {
			authError(c, 503, "authentication_unavailable", "Could not check email verification; retry")
			return
		}
	}
	c.JSON(http.StatusOK, struct {
		*models.User
		EmailVerified bool `json:"email_verified"`
	}{user, verified})
}

// RefreshToken issues a new JWT token for an authenticated user.
// POST /api/v1/auth/refresh
//
// This endpoint allows clients to obtain a fresh token before the current
// one expires. Call this periodically (e.g., every hour) to maintain
// the session without requiring re-login.
