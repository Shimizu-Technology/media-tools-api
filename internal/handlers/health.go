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
	"github.com/Shimizu-Technology/media-tools-api/internal/services/summary"
	webhookservice "github.com/Shimizu-Technology/media-tools-api/internal/services/webhook"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/worker"
)

// Handler holds shared dependencies for all HTTP handlers.
// Go Pattern: Dependency injection via struct fields. Instead of global
// variables or service locators, we pass dependencies explicitly.
// This makes testing easy — just create a Handler with mock dependencies.
type Handler struct {
	DB               *database.DB
	Worker           *worker.Pool
	AudioTranscriber *audio.Transcriber            // MTA-16: Whisper API transcriber
	WebhookService   *webhookservice.Service       // MTA-18: Webhook notifications
	Summarizer       *summary.Service              // MTA-22: AI summary service
	JWTSecret        string                        // MTA-20: JWT signing secret
	AdminAPIKey      string                        // Admin key for protected bootstrap operations
}

// NewHandler creates a new handler with all dependencies.
func NewHandler(db *database.DB, wp *worker.Pool, at *audio.Transcriber, ws *webhookservice.Service, sum *summary.Service, jwtSecret, adminAPIKey string) *Handler {
	return &Handler{
		DB:               db,
		Worker:           wp,
		AudioTranscriber: at,
		WebhookService:   ws,
		Summarizer:       sum,
		JWTSecret:        jwtSecret,
		AdminAPIKey:      adminAPIKey,
	}
}

// HealthCheck returns the API health status.
// GET /api/v1/health
func (h *Handler) HealthCheck(c *gin.Context) {
	// Check database connectivity
	dbStatus := "healthy"
	if err := h.DB.HealthCheck(c.Request.Context()); err != nil {
		dbStatus = "unhealthy: " + err.Error()
	}

	c.JSON(http.StatusOK, models.HealthResponse{
		Status:   "ok",
		Version:  "1.0.0",
		Database: dbStatus,
		Workers:  h.Worker.WorkerCount(),
	})
}
