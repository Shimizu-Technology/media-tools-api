package middleware

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

// RequireCompletedOnboarding keeps ordinary account APIs unavailable until
// server-persisted recovery setup is complete. API-key callers remain usable;
// the requirement belongs to an interactive user account session.
func RequireCompletedOnboarding() gin.HandlerFunc {
	return func(c *gin.Context) {
		user := GetUser(c)
		if user != nil && user.OnboardingRequired {
			c.JSON(http.StatusPreconditionRequired, models.ErrorResponse{
				Error: "onboarding_required", Message: "Finish passkey and recovery-code setup to continue", Code: http.StatusPreconditionRequired,
			})
			c.Abort()
			return
		}
		c.Next()
	}
}
