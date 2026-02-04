// Package router sets up all HTTP routes for the API.
package router

import (
	"net/http"
	"os"
	"path/filepath"
	"strings"

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
func Setup(db *database.DB, wp *worker.Pool, at *audio.Transcriber, ws *webhookservice.Service, sum *summary.Service, jwtSecret, adminAPIKey string, allowedOrigins []string) *gin.Engine {
	r := gin.Default()

	// Set max multipart form size to 30MB (slightly above our 25MB limit for headers/overhead)
	r.MaxMultipartMemory = 30 << 20 // 30MB

	r.Use(middleware.CORS(allowedOrigins))

	h := handlers.NewHandler(db, wp, at, ws, sum, jwtSecret, adminAPIKey)
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
		jwtProtected.POST("/auth/refresh", h.RefreshToken)
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
		protected.DELETE("/transcripts/:id", h.DeleteTranscript)
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
		protected.DELETE("/audio/transcriptions/:id", h.DeleteAudioTranscription)
		protected.GET("/audio/transcriptions/:id/export", h.ExportAudioTranscription) // MTA-26
		protected.POST("/audio/transcriptions/:id/summarize", h.SummarizeAudio)       // MTA-22
		protected.GET("/audio/transcriptions", h.ListAudioTranscriptions)

		// PDF extraction endpoints (MTA-17)
		protected.POST("/pdf/extract", h.ExtractPDF)
		protected.GET("/pdf/extractions/:id", h.GetPDFExtraction)
		protected.DELETE("/pdf/extractions/:id", h.DeletePDFExtraction)
		protected.GET("/pdf/extractions", h.ListPDFExtractions)

		// Webhook management (MTA-18)
		protected.POST("/webhooks", h.CreateWebhook)
		protected.GET("/webhooks", h.ListWebhooks)
		protected.GET("/webhooks/deliveries", h.ListWebhookDeliveries)
		protected.PATCH("/webhooks/:id", h.UpdateWebhook)
		protected.DELETE("/webhooks/:id", h.DeleteWebhook)
	}

	// --- Static Frontend Serving (SPA) ---
	// In production/Docker, the Go server serves the React frontend.
	// In development, Vite runs separately on :5173 and proxies API calls here.
	//
	// This is the Go equivalent of Rails' public/ directory — any request
	// that doesn't match an API route gets the React app.
	frontendDir := "frontend/dist"
	if _, err := os.Stat(frontendDir); err == nil {
		// Serve static assets (JS, CSS, images)
		r.Static("/assets", filepath.Join(frontendDir, "assets"))

		// Serve the SPA index.html for all non-API routes
		// This lets React Router handle client-side routing (/audio, /history, etc.)
		r.NoRoute(func(c *gin.Context) {
			// Don't serve index.html for API routes — return proper 404
			if strings.HasPrefix(c.Request.URL.Path, "/api/") {
				c.JSON(http.StatusNotFound, gin.H{"error": "not_found", "message": "API endpoint not found"})
				return
			}
			c.File(filepath.Join(frontendDir, "index.html"))
		})
	}

	return r
}
