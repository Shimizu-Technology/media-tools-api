package middleware

import (
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
)

const maxJSONBodyBytes = 2 << 20 // 2 MiB is ample for API DTOs and chat prompts.

// SecurityHeaders adds browser protections that are safe for both JSON API
// responses and the optional SPA served by the Go binary.
func SecurityHeaders() gin.HandlerFunc {
	return func(c *gin.Context) {
		h := c.Writer.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "strict-origin-when-cross-origin")
		h.Set("Permissions-Policy", "camera=(), geolocation=(), payment=(), usb=()")
		if c.Request.TLS != nil || strings.EqualFold(c.GetHeader("X-Forwarded-Proto"), "https") {
			h.Set("Strict-Transport-Security", "max-age=31536000; includeSubDomains")
		}
		c.Next()
	}
}

// LimitJSONBody prevents small JSON endpoints from accepting unbounded bodies.
// Multipart upload handlers keep their purpose-specific limits.
func LimitJSONBody() gin.HandlerFunc {
	return func(c *gin.Context) {
		if strings.HasPrefix(strings.ToLower(c.GetHeader("Content-Type")), "application/json") {
			c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, maxJSONBodyBytes)
		}
		c.Next()
	}
}
