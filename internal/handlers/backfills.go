package handlers

import (
	"database/sql"
	"errors"
	"log"
	"net/http"
	"strings"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

func (h *Handler) CreateBackfill(c *gin.Context) {
	reject := func(code int, message string) {
		c.JSON(code, models.ErrorResponse{Error: http.StatusText(code), Message: message, Code: code})
	}
	if !h.requireBackfillAdmin(c) {
		return
	}
	var req struct {
		Kind   string `json:"kind"`
		UserID string `json:"user_id"`
		DryRun *bool  `json:"dry_run"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		reject(400, "Invalid backfill request")
		return
	}
	if req.Kind != "waveforms" && req.Kind != "enrichment" {
		reject(400, "kind must be waveforms or enrichment")
		return
	}
	if req.Kind == "enrichment" {
		parsed, err := uuid.Parse(req.UserID)
		if err != nil {
			reject(400, "enrichment requires a valid user_id")
			return
		}
		req.UserID = parsed.String()
	}
	if req.Kind == "waveforms" && req.UserID != "" {
		reject(400, "waveforms covers all accounts; omit user_id")
		return
	}
	if req.DryRun == nil {
		reject(400, "dry_run must be explicitly true or false")
		return
	}
	if h.DB == nil {
		log.Printf("Backfill request has no configured database")
		reject(503, "Backfill database is unavailable")
		return
	}

	if req.Kind == "enrichment" {
		var exists bool
		err := h.DB.GetContext(c.Request.Context(), &exists, `SELECT EXISTS(SELECT 1 FROM users WHERE id=$1::uuid)`, req.UserID)
		if err != nil {
			log.Printf("Backfill account lookup failed: %v", err)
			reject(503, "Backfill account lookup is unavailable")
			return
		}
		if !exists {
			c.JSON(404, models.ErrorResponse{Error: "account_not_found", Message: "Backfill account not found", Code: 404})
			return
		}
	}

	if h.Worker == nil {
		log.Printf("Backfill request has no configured worker")
		reject(503, "Background worker is unavailable")
		return
	}
	if !*req.DryRun {
		id, err := h.DB.CreateBackfillRun(c.Request.Context(), req.Kind, req.UserID)
		if err != nil {
			log.Printf("Create backfill run failed: %v", err)
			reject(503, "Backfill could not be queued")
			return
		}
		h.Worker.Wake()
		c.JSON(http.StatusAccepted, gin.H{"id": id, "kind": req.Kind, "dry_run": false})
		return
	}
	result, err := h.Worker.RunBackfill(c.Request.Context(), req.Kind, req.UserID, *req.DryRun)
	if err != nil {
		log.Printf("Backfill preview failed: %v", err)
		reject(503, "Backfill could not be queued; retry the same request safely")
		return
	}
	status := http.StatusAccepted
	if *req.DryRun {
		status = http.StatusOK
	}
	c.JSON(status, result)
}

func (h *Handler) GetBackfill(c *gin.Context) {
	if !h.requireBackfillAdmin(c) {
		return
	}
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		c.JSON(400, models.ErrorResponse{Error: "invalid_id", Message: "Invalid backfill id", Code: 400})
		return
	}
	if h.DB == nil {
		log.Printf("Backfill progress has no configured database")
		c.JSON(503, models.ErrorResponse{Error: "unavailable", Message: "Backfill progress is unavailable", Code: 503})
		return
	}

	progress, err := h.DB.GetBackfillProgress(c.Request.Context(), id.String())
	if errors.Is(err, sql.ErrNoRows) {
		c.JSON(404, models.ErrorResponse{Error: "not_found", Message: "Backfill run not found", Code: 404})
		return
	}
	if err != nil {
		log.Printf("Backfill progress lookup failed: %v", err)
		c.JSON(503, models.ErrorResponse{Error: "unavailable", Message: "Backfill progress is unavailable", Code: 503})
		return
	}
	c.JSON(200, progress)
}

func (h *Handler) requireBackfillAdmin(c *gin.Context) bool {
	reject := func(code int, message string) bool {
		c.JSON(code, models.ErrorResponse{Error: http.StatusText(code), Message: message, Code: code})
		return false
	}
	if c.GetHeader("X-API-Key") != "" || c.GetHeader("Authorization") != "" {
		return reject(403, "Use only X-Admin-Key for this route")
	}
	if strings.TrimSpace(c.GetHeader("X-Admin-Key")) == "" {
		return reject(401, "X-Admin-Key header is required")
	}
	if !adminKeyMatches(c.GetHeader("X-Admin-Key"), h.AdminAPIKey) {
		return reject(403, "Invalid admin key")
	}
	return true
}
