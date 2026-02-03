// Package router sets up all HTTP routes for the API.
package router

import (
	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/handlers"
	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/audio"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/summary"
	webhookservice "github.com/Shimizu-Technology/media-tools-api/internal/services/webhook"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/worker"
)

// Setup creates and configures the Gin router with all routes.
func Setup(db *database.DB, wp *worker.Pool, at *audio.Transcriber, ws *webhookservice.Service, sum *summary.Service, jwtSecret string, allowedOrigins []string) *gin.Engine {
	r := gin.Default()
	r.Use(middleware.CORS(allowedOrigins))

	h := handlers.NewHandler(db, wp, at, ws, sum, jwtSecret)
	rateLimiter := middleware.NewRateLimiter()

	// --- Public Routes (no auth required) ---
	r.GET("/api/v1/health", h.HealthCheck)
	r.POST("/api/v1/keys", h.CreateAPIKey)

	// API Documentation (MTA-10)
	r.GET("/api/docs", h.ServeSwaggerUI)
	r.GET("/api/docs/openapi.yaml", h.ServeOpenAPISpec)

	// --- Auth Routes (MTA-20) — public ---
	r.POST("/api/v1/auth/register", h.Register)
	r.POST("/api/v1/auth/login", h.Login)

	// --- JWT-protected routes (MTA-20) ---
	jwtProtected := r.Group("/api/v1")
	jwtProtected.Use(middleware.JWTAuth(db, jwtSecret))
	{
		jwtProtected.GET("/auth/me", h.GetMe)
		jwtProtected.GET("/workspace", h.GetWorkspace)
		jwtProtected.POST("/workspace", h.SaveToWorkspace)
		jwtProtected.DELETE("/workspace/:type/:id", h.RemoveFromWorkspace)
	}

	// --- Protected Routes (API key OR JWT — backward compatible) ---
	protected := r.Group("/api/v1")
	protected.Use(middleware.DualAuth(db, jwtSecret))
	protected.Use(rateLimiter.RateLimit())
	{
		// Transcript endpoints
		protected.POST("/transcripts", h.CreateTranscript)
		protected.GET("/transcripts", h.ListTranscripts)
		protected.GET("/transcripts/:id", h.GetTranscript)
		protected.GET("/transcripts/:id/summaries", h.GetSummariesByTranscript)
		protected.GET("/transcripts/:id/export", h.ExportTranscript)

		// Batch processing (MTA-8)
		protected.POST("/transcripts/batch", h.CreateBatch)
		protected.GET("/batches/:id", h.GetBatch)

		// Summary endpoints
		protected.POST("/summaries", h.CreateSummary)

		// API key management
		protected.GET("/keys", h.ListAPIKeys)
		protected.DELETE("/keys/:id", h.RevokeAPIKey)

		// Audio transcription endpoints (MTA-16, MTA-22, MTA-25, MTA-26)
		protected.POST("/audio/transcribe", h.TranscribeAudio)
		protected.GET("/audio/transcriptions/search", h.SearchAudioTranscriptions) // MTA-25: must be before :id
		protected.GET("/audio/transcriptions/:id", h.GetAudioTranscription)
		protected.GET("/audio/transcriptions/:id/export", h.ExportAudioTranscription) // MTA-26
		protected.POST("/audio/transcriptions/:id/summarize", h.SummarizeAudio)       // MTA-22
		protected.GET("/audio/transcriptions", h.ListAudioTranscriptions)

		// PDF extraction endpoints (MTA-17)
		protected.POST("/pdf/extract", h.ExtractPDF)
		protected.GET("/pdf/extractions/:id", h.GetPDFExtraction)
		protected.GET("/pdf/extractions", h.ListPDFExtractions)

		// Webhook management (MTA-18)
		protected.POST("/webhooks", h.CreateWebhook)
		protected.GET("/webhooks", h.ListWebhooks)
		protected.GET("/webhooks/deliveries", h.ListWebhookDeliveries)
		protected.PATCH("/webhooks/:id", h.UpdateWebhook)
		protected.DELETE("/webhooks/:id", h.DeleteWebhook)
	}

	return r
}
