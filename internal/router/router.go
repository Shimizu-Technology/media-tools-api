// Package router sets up all HTTP routes for the API.
//
// Go Pattern: We separate route configuration from handlers.
// This keeps main.go clean and makes it easy to see all routes at a glance.
//
// Framework choice: Gin
// We chose Gin over Echo because:
// - Larger community and more learning resources (important for Leon's first Go project)
// - Similar to Express.js in feel (familiar to JavaScript developers)
// - Excellent middleware ecosystem (CORS, logging, recovery)
// - Great performance (one of the fastest Go HTTP frameworks)
// - Well-documented with many examples
package router

import (
	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/handlers"
	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/worker"
)

// Setup creates and configures the Gin router with all routes.
func Setup(db *database.DB, wp *worker.Pool, allowedOrigins []string) *gin.Engine {
	// Create the Gin router with default middleware:
	// - Logger: logs every request (method, path, status, duration)
	// - Recovery: catches panics and returns 500 instead of crashing
	r := gin.Default()

	// Add our custom middleware
	r.Use(middleware.CORS(allowedOrigins))

	// Create the handler with dependencies
	h := handlers.NewHandler(db, wp)

	// Create the rate limiter (shared across all routes)
	rateLimiter := middleware.NewRateLimiter()

	// --- Public Routes (no auth required) ---
	// These are accessible without an API key.
	// Health check is always public for monitoring tools.
	r.GET("/api/v1/health", h.HealthCheck)

	// API key creation is public (bootstrap: you need a key to use the API,
	// but you need to be able to CREATE a key without one).
	// In production, protect this with a master key or admin auth.
	r.POST("/api/v1/keys", h.CreateAPIKey)

	// --- Protected Routes (API key required) ---
	// Go Pattern: Gin's Group() creates a route group that shares middleware.
	// All routes inside this group require a valid API key.
	protected := r.Group("/api/v1")
	protected.Use(middleware.APIKeyAuth(db))
	protected.Use(rateLimiter.RateLimit())
	{
		// Transcript endpoints
		protected.POST("/transcripts", h.CreateTranscript)
		protected.GET("/transcripts", h.ListTranscripts)
		protected.GET("/transcripts/:id", h.GetTranscript)
		protected.GET("/transcripts/:id/summaries", h.GetSummariesByTranscript)

		// Summary endpoints
		protected.POST("/summaries", h.CreateSummary)

		// API key management
		protected.GET("/keys", h.ListAPIKeys)
		protected.DELETE("/keys/:id", h.RevokeAPIKey)
	}

	return r
}
