// cors.go configures Cross-Origin Resource Sharing (CORS).
//
// CORS is needed because the React frontend (localhost:5173) and the
// Go API (localhost:8080) run on different ports. Without CORS headers,
// browsers block the frontend from making API requests.
package middleware

import (
	"time"

	"github.com/gin-contrib/cors"
	"github.com/gin-gonic/gin"
)

// CORS returns configured CORS middleware.
func CORS(allowedOrigins []string) gin.HandlerFunc {
	return cors.New(cors.Config{
		AllowOrigins:     allowedOrigins,
		AllowMethods:     []string{"GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"},
		AllowHeaders:     []string{"Origin", "Content-Type", "Accept", "Authorization", "X-API-Key"},
		ExposeHeaders:    []string{"X-RateLimit-Limit", "X-RateLimit-Remaining", "Content-Length"},
		AllowCredentials: true,
		MaxAge:           12 * time.Hour, // Cache preflight responses
	})
}
