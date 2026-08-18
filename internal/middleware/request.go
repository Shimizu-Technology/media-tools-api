package middleware

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"log"
	"net/http"
	"runtime/debug"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

const requestIDHeader = "X-Request-ID"
const requestIDContextKey = "request_id"

// RequestID gives every request a safe correlation identifier. Clients may
// provide their own identifier so frontend and native logs can be joined to a
// backend request, but unsafe values are replaced before they reach headers or
// logs.
func RequestID() gin.HandlerFunc {
	return func(c *gin.Context) {
		requestID := c.GetHeader(requestIDHeader)
		if !validRequestID(requestID) {
			requestID = newRequestID()
		}

		c.Set(requestIDContextKey, requestID)
		c.Header(requestIDHeader, requestID)
		c.Next()
	}
}

// GetRequestID returns the correlation identifier assigned by RequestID.
func GetRequestID(c *gin.Context) string {
	requestID, _ := c.Get(requestIDContextKey)
	value, _ := requestID.(string)
	return value
}

// AccessLog emits one bounded logfmt record per request without query strings,
// request bodies, authorization headers, or other credential-bearing values.
// Successful health probes are omitted to keep production logs useful.
func AccessLog() gin.HandlerFunc {
	return func(c *gin.Context) {
		startedAt := time.Now()
		c.Next()

		status := c.Writer.Status()
		path := c.Request.URL.Path
		if status < http.StatusInternalServerError && isHealthProbe(path) {
			return
		}

		log.Printf(
			"http_request request_id=%q method=%q path=%q route=%q status=%d duration_ms=%d response_bytes=%d client_ip=%q",
			GetRequestID(c),
			c.Request.Method,
			path,
			c.FullPath(),
			status,
			time.Since(startedAt).Milliseconds(),
			c.Writer.Size(),
			c.ClientIP(),
		)
	}
}

// Recovery converts panics into the API's standard error shape while logging
// the request ID and stack trace. It intentionally excludes request headers
// because they can contain API keys and bearer tokens.
func Recovery() gin.HandlerFunc {
	return gin.CustomRecovery(func(c *gin.Context, recovered any) {
		log.Printf(
			"http_panic request_id=%q method=%q path=%q error=%q stack=%q",
			GetRequestID(c),
			c.Request.Method,
			c.Request.URL.Path,
			fmt.Sprint(recovered),
			debug.Stack(),
		)
		c.AbortWithStatusJSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "internal_error",
			Message: "An unexpected error occurred",
			Code:    http.StatusInternalServerError,
		})
	})
}

func newRequestID() string {
	bytes := make([]byte, 16)
	if _, err := rand.Read(bytes); err == nil {
		return hex.EncodeToString(bytes)
	}
	// crypto/rand failures are exceptionally rare. A time-based fallback keeps
	// the request traceable instead of dropping the header entirely.
	return strconv.FormatInt(time.Now().UnixNano(), 36)
}

func validRequestID(value string) bool {
	if value == "" || len(value) > 64 {
		return false
	}
	for _, char := range value {
		if (char >= 'a' && char <= 'z') ||
			(char >= 'A' && char <= 'Z') ||
			(char >= '0' && char <= '9') ||
			char == '-' || char == '_' || char == '.' || char == ':' {
			continue
		}
		return false
	}
	return true
}

func isHealthProbe(path string) bool {
	switch path {
	case "/health", "/ready", "/api/v1/health", "/api/v1/ready":
		return true
	default:
		return false
	}
}
