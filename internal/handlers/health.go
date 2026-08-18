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
	"context"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/audio"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/storage"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/summary"
	webhookservice "github.com/Shimizu-Technology/media-tools-api/internal/services/webhook"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/worker"
)

type readinessChecker interface {
	HealthCheck(context.Context) error
}

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
	Version                string                  // Build version reported by health endpoints
	readinessChecker       readinessChecker
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
		readinessChecker:       db,
	}
}

// HealthCheck is a process-only liveness probe. It deliberately avoids the
// database so infrastructure probes do not prevent Neon from scaling to zero.
// GET /api/v1/health
func (h *Handler) HealthCheck(c *gin.Context) {
	c.JSON(http.StatusOK, h.healthResponse("ok", "unchecked"))
}

// ReadinessCheck verifies that the API can reach its database. It is intended
// for explicit diagnostics, not high-frequency infrastructure polling.
// GET /api/v1/ready
func (h *Handler) ReadinessCheck(c *gin.Context) {
	if h.readinessChecker == nil {
		c.JSON(http.StatusServiceUnavailable, h.healthResponse("unhealthy", "unhealthy"))
		return
	}

	ctx, cancel := context.WithTimeout(c.Request.Context(), 3*time.Second)
	defer cancel()
	if err := h.readinessChecker.HealthCheck(ctx); err != nil {
		c.JSON(http.StatusServiceUnavailable, h.healthResponse("unhealthy", "unhealthy"))
		return
	}

	c.JSON(http.StatusOK, h.healthResponse("ok", "healthy"))
}

func (h *Handler) healthResponse(status, databaseStatus string) models.HealthResponse {
	workers := 0
	if h.Worker != nil {
		workers = h.Worker.WorkerCount()
	}
	version := h.Version
	if version == "" {
		version = "dev"
	}
	return models.HealthResponse{
		Status:                 status,
		Version:                version,
		Database:               databaseStatus,
		Workers:                workers,
		YtDlpCookiesConfigured: h.YtDlpCookiesConfigured,
	}
}
