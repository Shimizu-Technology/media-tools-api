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
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/audio"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/storage"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/summary"
	webhookservice "github.com/Shimizu-Technology/media-tools-api/internal/services/webhook"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/worker"
)

// RouterConfig holds all dependencies for the router setup.
// Avoids a fragile 13-parameter function signature.
type RouterConfig struct {
	// Version is the build identifier exposed by health endpoints.
	Version                     string
	DB                          *database.DB
	WorkerPool                  *worker.Pool
	AudioTranscriber            *audio.Transcriber
	AudioStorage                *storage.S3
	Webhooks                    *webhookservice.Service
	Summarizer                  *summary.Service
	JWTSecret                   string
	LegacyAuthEnabled           bool
	AdminAPIKey                 string
	OwnerKeyID                  string
	OwnerKeyPrefix              string
	ClerkJWKSURL                string
	ClerkSecretKey              string
	ClerkIssuer                 string
	ClerkAudience               string
	ClerkAuthorizedParty        string
	AllowedOrigins              []string
	DefaultRateLimit            int
	DefaultBrowserReadRateLimit int
	YtDlpCookiesConfigured      bool
}

// Setup creates and configures the Gin router with all routes.
func Setup(cfg RouterConfig) *gin.Engine {
	r := gin.New()

	// Keep multipart parsing memory bounded; larger uploads are streamed to temp files.
	r.MaxMultipartMemory = 120 << 20

	r.Use(middleware.RequestID())
	r.Use(middleware.AccessLog())
	r.Use(middleware.Recovery())
	r.Use(middleware.SecurityHeaders())
	r.Use(middleware.LimitJSONBody())
	r.Use(middleware.CORS(cfg.AllowedOrigins))

	h := handlers.NewHandler(cfg.DB, cfg.WorkerPool, cfg.AudioTranscriber, cfg.AudioStorage, cfg.Webhooks, cfg.Summarizer, cfg.JWTSecret, cfg.AdminAPIKey, cfg.OwnerKeyID, cfg.OwnerKeyPrefix, cfg.YtDlpCookiesConfigured)
	h.Version = cfg.Version
	rateLimiter := middleware.NewRateLimiter(
		cfg.OwnerKeyID,
		cfg.OwnerKeyPrefix,
		cfg.DefaultRateLimit,
		cfg.DefaultBrowserReadRateLimit,
	)

	// Initialize Clerk JWKS cache if configured
	var jwksCache *middleware.JWKSCache
	if cfg.ClerkJWKSURL != "" {
		jwksCache = middleware.NewJWKSCache(cfg.ClerkJWKSURL, cfg.ClerkIssuer, cfg.ClerkAudience, cfg.ClerkAuthorizedParty)
	}

	// --- Public Routes (no auth required) ---
	r.GET("/health", h.HealthCheck) // Render-style health check alias
	r.GET("/api/v1/health", h.HealthCheck)
	r.GET("/ready", h.ReadinessCheck)
	r.GET("/api/v1/ready", h.ReadinessCheck)
	r.POST("/api/v1/keys", h.CreateAPIKey)

	// API Documentation (MTA-10)
	r.GET("/api/docs", h.ServeSwaggerUI)
	r.GET("/api/docs/openapi.yaml", h.ServeOpenAPISpec)

	// --- Legacy Auth Routes (MTA-20) ---
	// Browser auth is Clerk-first. Legacy email/password auth is kept only when
	// explicitly enabled (local/dev compatibility) so production cannot bypass
	// Clerk by registering directly against the API.
	if cfg.LegacyAuthEnabled {
		r.POST("/api/v1/auth/register", h.Register)
		r.POST("/api/v1/auth/login", h.Login)
	}

	// --- JWT-protected routes (MTA-20) — accepts Clerk or legacy JWT ---
	jwtProtected := r.Group("/api/v1")
	if jwksCache != nil {
		jwtProtected.Use(middleware.BearerOnlyAuth(cfg.DB, cfg.JWTSecret, jwksCache, cfg.ClerkSecretKey))
	} else {
		jwtProtected.Use(middleware.JWTAuth(cfg.DB, cfg.JWTSecret))
	}
	{
		jwtProtected.GET("/auth/me", h.GetMe)
		if cfg.LegacyAuthEnabled {
			jwtProtected.POST("/auth/refresh", h.RefreshToken)
		}
		jwtProtected.GET("/workspace", h.GetWorkspace)
		jwtProtected.POST("/workspace", h.SaveToWorkspace)
		jwtProtected.DELETE("/workspace/:type/:id", h.RemoveFromWorkspace)
	}

	// --- Protected Routes (API key OR Clerk JWT OR legacy JWT — backward compatible) ---
	protected := r.Group("/api/v1")
	protected.Use(middleware.DualAuth(cfg.DB, cfg.JWTSecret, jwksCache, cfg.ClerkSecretKey))
	protected.Use(rateLimiter.RateLimit())
	{
		// Transcript endpoints
		protected.POST("/transcripts", h.CreateTranscript)
		protected.GET("/transcripts", h.ListTranscripts)
		protected.GET("/transcripts/:id", h.GetTranscript)
		protected.DELETE("/transcripts/:id", h.DeleteTranscript)
		protected.GET("/transcripts/:id/summaries", h.GetSummariesByTranscript)
		protected.GET("/transcripts/:id/chat", h.GetTranscriptChat)
		protected.POST("/transcripts/:id/chat", h.PostTranscriptChat)
		protected.GET("/transcripts/:id/export", h.ExportTranscript)

		// Batch processing (MTA-8)
		protected.POST("/transcripts/batch", h.CreateBatch)
		protected.GET("/batches/:id", h.GetBatch)

		// Summary endpoints
		protected.POST("/summaries", h.CreateSummary)

		// API key management
		protected.GET("/keys", h.ListAPIKeys)
		protected.POST("/user/keys", h.CreateUserAPIKey)
		protected.DELETE("/keys/:id", h.RevokeAPIKey)

		// Audio transcription endpoints (MTA-16, MTA-22, MTA-25, MTA-26)
		protected.POST("/audio/transcribe", h.TranscribeAudio)
		protected.POST("/audio/uploads/presign", h.PresignAudioUpload)
		protected.POST("/audio/uploads/complete", h.CompleteAudioUpload)
		protected.GET("/audio/transcriptions/search", h.SearchAudioTranscriptions) // MTA-25: must be before :id
		protected.GET("/audio/transcriptions/:id", h.GetAudioTranscription)
		protected.PATCH("/audio/transcriptions/:id", h.RenameAudioTranscription)
		protected.POST("/audio/transcriptions/:id/cancel", h.CancelAudioTranscription)
		protected.POST("/audio/transcriptions/:id/retry", h.RetryAudioTranscription)
		protected.POST("/audio/transcriptions/:id/format", h.FormatAudioTranscript)
		protected.GET("/audio/transcriptions/:id/audio", h.GetAudioPlaybackURL)
		protected.DELETE("/audio/transcriptions/:id", h.DeleteAudioTranscription)
		protected.GET("/audio/transcriptions/:id/export", h.ExportAudioTranscription) // MTA-26
		protected.POST("/audio/transcriptions/:id/summarize", h.SummarizeAudio)       // MTA-22
		protected.GET("/audio/transcriptions/:id/chat", h.GetAudioChat)
		protected.POST("/audio/transcriptions/:id/chat", h.PostAudioChat)
		protected.GET("/audio/transcriptions", h.ListAudioTranscriptions)

		// PDF extraction endpoints (MTA-17)
		protected.POST("/pdf/extract", h.ExtractPDF)
		protected.GET("/pdf/extractions/:id", h.GetPDFExtraction)
		protected.DELETE("/pdf/extractions/:id", h.DeletePDFExtraction)
		protected.GET("/pdf/extractions/:id/chat", h.GetPDFChat)
		protected.POST("/pdf/extractions/:id/chat", h.PostPDFChat)
		protected.GET("/pdf/extractions", h.ListPDFExtractions)

		// Collections (grouping transcripts, audio, PDFs)
		protected.GET("/collections", h.ListCollections)
		protected.POST("/collections", h.CreateCollection)
		protected.GET("/collections/:id", h.GetCollection)
		protected.PATCH("/collections/:id", h.UpdateCollection)
		protected.DELETE("/collections/:id", h.DeleteCollection)
		protected.POST("/collections/:id/items", h.AddCollectionItems)
		protected.DELETE("/collections/:id/items/:itemId", h.RemoveCollectionItem)
		protected.GET("/collections/:id/chat", h.GetCollectionChat)
		protected.POST("/collections/:id/chat", h.PostCollectionChat)

		// Unified library and exact workspace metrics
		protected.GET("/library/items", h.ListLibraryItems)
		protected.GET("/library/stats", h.GetLibraryStats)
		protected.GET("/library/items/:type/:id/preferences", h.GetLibraryPreferences)
		protected.PATCH("/library/items/:type/:id/preferences", h.UpdateLibraryPreferences)
		protected.GET("/library/items/:type/:id/segments", h.GetMediaSegments)

		// Webhook management (MTA-18)
		protected.POST("/webhooks", h.CreateWebhook)
		protected.GET("/webhooks", h.ListWebhooks)
		protected.GET("/webhooks/deliveries", h.ListWebhookDeliveries)
		protected.PATCH("/webhooks/:id", h.UpdateWebhook)
		protected.DELETE("/webhooks/:id", h.DeleteWebhook)

		// Ops
		protected.GET("/ops/audio/health", h.GetAudioOpsHealth)
	}

	// --- Static Frontend Serving (SPA) ---
	// In production/Docker, the Go server serves the React frontend.
	// In development, Vite runs separately on :5173 and proxies API calls here.
	//
	// This is the Go equivalent of Rails' public/ directory — any request
	// that doesn't match an API route gets the React app.
	frontendDir := "frontend/dist"
	frontendAvailable := false
	if info, err := os.Stat(frontendDir); err == nil && info.IsDir() {
		frontendAvailable = true
		// Serve static assets (JS, CSS, images)
		r.Static("/assets", filepath.Join(frontendDir, "assets"))
	}

	// Serve the SPA index.html for all non-API routes when a production build is
	// bundled. API misses always keep the documented error contract, including
	// local/test deployments where frontend/dist is absent.
	r.NoRoute(func(c *gin.Context) {
		if strings.HasPrefix(c.Request.URL.Path, "/api/") || !frontendAvailable {
			c.JSON(http.StatusNotFound, models.ErrorResponse{
				Error:   "not_found",
				Message: "Endpoint not found",
				Code:    http.StatusNotFound,
			})
			return
		}

		cleanPath := strings.TrimPrefix(filepath.Clean(c.Request.URL.Path), string(filepath.Separator))
		if cleanPath != "." && cleanPath != "" {
			candidate := filepath.Join(frontendDir, cleanPath)
			if rel, err := filepath.Rel(frontendDir, candidate); err == nil && !strings.HasPrefix(rel, "..") {
				if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
					c.File(candidate)
					return
				}
			}
		}

		c.File(filepath.Join(frontendDir, "index.html"))
	})

	return r
}
