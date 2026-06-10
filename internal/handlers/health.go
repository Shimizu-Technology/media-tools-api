// Package handlers contains HTTP handler functions for the API.
//
// Go Pattern: Handlers in Gin receive a *gin.Context which provides:
// - Request data (params, query, body, headers)
// - Response methods (JSON, String, Status)
// - Middleware data (c.Get/c.Set)
//
// Unlike Ruby controllers, Go handlers are plain functions — no class inheritance.
// We group related handlers into a struct (Handler) that holds shared dependencies.
package handlers

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/audio"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/storage"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/summary"
	webhookservice "github.com/Shimizu-Technology/media-tools-api/internal/services/webhook"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/worker"
)

// Handler holds shared dependencies for all HTTP handlers.
// Go Pattern: Dependency injection via struct fields. Instead of global
// variables or service locators, we pass dependencies explicitly.
// This makes testing easy — just create a Handler with mock dependencies.
type Handler struct {
	DB                     *database.DB
	Worker                 *worker.Pool
	AudioTranscriber       *audio.Transcriber      // MTA-16: Whisper API transcriber
	AudioStorage           *storage.S3             // Raw audio storage + playback URLs
	WebhookService         *webhookservice.Service // MTA-18: Webhook notifications
	Summarizer             *summary.Service        // MTA-22: AI summary service
	JWTSecret              string                  // MTA-20: JWT signing secret
	AdminAPIKey            string                  // Admin key for protected bootstrap operations
	OwnerAPIKeyID          string                  // Optional owner key ID override
	OwnerAPIKeyPrefix      string                  // Optional owner key prefix override
	YtDlpCookiesConfigured bool                    // True when yt-dlp cookies are configured
}

// NewHandler creates a new handler with all dependencies.
func NewHandler(db *database.DB, wp *worker.Pool, at *audio.Transcriber, as *storage.S3, ws *webhookservice.Service, sum *summary.Service, jwtSecret, adminAPIKey, ownerKeyID, ownerKeyPrefix string, ytDlpCookiesConfigured bool) *Handler {
	return &Handler{
		DB:                     db,
		Worker:                 wp,
		AudioTranscriber:       at,
		AudioStorage:           as,
		WebhookService:         ws,
		Summarizer:             sum,
		JWTSecret:              jwtSecret,
		AdminAPIKey:            adminAPIKey,
		OwnerAPIKeyID:          ownerKeyID,
		OwnerAPIKeyPrefix:      ownerKeyPrefix,
		YtDlpCookiesConfigured: ytDlpCookiesConfigured,
	}
}

// HealthCheck returns the API health status.
// GET /api/v1/health
func (h *Handler) HealthCheck(c *gin.Context) {
	// Check database connectivity. Return a failing HTTP status when dependencies
	// are down so Render/Docker health checks do not keep routing traffic to an
	// unhealthy instance.
	dbStatus := "healthy"
	status := "ok"
	httpStatus := http.StatusOK
	if err := h.DB.HealthCheck(c.Request.Context()); err != nil {
		dbStatus = "unhealthy: " + err.Error()
		status = "unhealthy"
		httpStatus = http.StatusServiceUnavailable
	}

	c.JSON(httpStatus, models.HealthResponse{
		Status:                 status,
		Version:                "1.0.0",
		Database:               dbStatus,
		Workers:                h.Worker.WorkerCount(),
		YtDlpCookiesConfigured: h.YtDlpCookiesConfigured,
	})
}
