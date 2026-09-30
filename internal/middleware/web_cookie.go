package middleware

import (
	"crypto/subtle"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

const (
	WebAccessCookie             = "mta_web_access"
	WebRefreshCookie            = "mta_web_refresh"
	WebPendingCookie            = "mta_web_pending"
	WebRecoveryPendingCookie    = "mta_web_recovery_pending"
	WebInvitationCookie         = "mta_web_invitation"
	WebOnboardingRescueCookie   = "mta_web_onboarding_rescue"
	WebOnboardingPendingCookie  = "mta_web_onboarding_pending"
	WebOnboardingRequiredCookie = "mta_web_onboarding_required"
	WebCSRFCookie               = "mta_web_csrf"
	WebCSRFHeader               = "X-CSRF-Token"
)

// ValidWebCookieMutation requires both an allowed page origin and a CSRF
// header matching this host's readable CSRF cookie. SameSite alone does not
// protect against another subdomain under the same registrable domain.
func ValidWebCookieMutation(c *gin.Context, allowedOrigins []string) bool {
	origin := c.GetHeader("Origin")
	allowed := false
	for _, candidate := range allowedOrigins {
		if origin != "" && origin == candidate {
			allowed = true
			break
		}
	}
	if !allowed {
		return false
	}
	cookie, err := c.Cookie(WebCSRFCookie)
	header := c.GetHeader(WebCSRFHeader)
	return err == nil && cookie != "" && header != "" && subtle.ConstantTimeCompare([]byte(cookie), []byte(header)) == 1
}

// WebCookieAuth lets first-party browser cookies use the existing bearer
// authorization and ownership checks. Explicit bearer and API-key callers are
// left alone, so native clients and agents retain their existing behavior.
func WebCookieAuth(allowedOrigins []string) gin.HandlerFunc {
	return func(c *gin.Context) {
		if !strings.HasPrefix(c.Request.URL.Path, "/api/v1/") ||
			strings.HasPrefix(c.Request.URL.Path, "/api/v1/auth/web/session/") ||
			c.GetHeader("Authorization") != "" || c.GetHeader("X-API-Key") != "" {
			c.Next()
			return
		}
		access, err := c.Cookie(WebAccessCookie)
		if err != nil || access == "" {
			c.Next()
			return
		}
		if c.Request.Method != http.MethodGet && c.Request.Method != http.MethodHead && c.Request.Method != http.MethodOptions {
			if !ValidWebCookieMutation(c, allowedOrigins) {
				c.JSON(http.StatusForbidden, models.ErrorResponse{Error: "csrf_invalid", Message: "Refresh the page and try again", Code: http.StatusForbidden})
				c.Abort()
				return
			}
		}
		c.Request.Header.Set("Authorization", "Bearer "+access)
		c.Next()
	}
}
