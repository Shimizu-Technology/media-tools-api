// transcripts.go handles all transcript-related HTTP endpoints.
package handlers

import (
	"encoding/json"
	"log"
	"math"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/transcript"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/worker"
)

// CreateTranscript starts transcript extraction for a video.
// POST /api/v1/transcripts
//
// Request body:
//
//	{"url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ"}
//	{"url": "https://vimeo.com/123456789"}
//	{"url": "https://any-yt-dlp-supported-site.com/video"}
//	  or
//	{"video_id": "dQw4w9WgXcQ"}
//
// Response: The created transcript record (status will be "pending").
// The actual extraction happens in the background via the worker pool.
func (h *Handler) CreateTranscript(c *gin.Context) {
	var req models.CreateTranscriptRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_request",
			Message: "Provide either 'url' or 'video_id' in the request body",
			Code:    http.StatusBadRequest,
		})
		return
	}

	// Parse the video URL (YouTube, Vimeo, or any yt-dlp-supported site)
	var parsed *transcript.ParsedVideo
	var err error

	if req.URL != "" {
		parsed, err = transcript.ParseVideoURL(req.URL)
	} else {
		parsed, err = transcript.ParseVideoURL(req.VideoID)
	}

	if err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_url",
			Message: err.Error(),
			Code:    http.StatusBadRequest,
		})
		return
	}
	if parsed.Source == transcript.SourceOther {
		if err := transcript.ValidateExternalVideoURL(c.Request.Context(), parsed.URL); err != nil {
			c.JSON(http.StatusBadRequest, models.ErrorResponse{
				Error:   "invalid_url",
				Message: err.Error(),
				Code:    http.StatusBadRequest,
			})
			return
		}
	}

	youtubeURL := parsed.URL
	videoID := parsed.VideoID

	actor := getActorOwnership(c)
	if !actor.IsAuthenticated() {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{
			Error:   "unauthorized",
			Message: "Authentication required",
			Code:    http.StatusUnauthorized,
		})
		return
	}

	// Check if we already have a transcript for this video
	existing, _ := h.DB.GetTranscriptByYouTubeIDForActor(c.Request.Context(), videoID, actor.UserID, actor.APIKeyID)
	if existing != nil && existing.Status == models.StatusCompleted {
		// Return the existing transcript instead of re-extracting
		c.JSON(http.StatusOK, existing)
		return
	}

	// Create a new transcript record with "pending" status
	owner := getActorWriteOwnership(c)
	t := &models.Transcript{
		YouTubeURL: youtubeURL,
		YouTubeID:  videoID,
		Status:     models.StatusPending,
		UserID:     owner.UserID,
		APIKeyID:   owner.APIKeyID,
	}

	if err := h.DB.CreateTranscript(c.Request.Context(), t); err != nil {
		log.Printf("❌ Failed to create transcript record: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to create transcript record",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	// Submit extraction job to the worker pool
	// Go Pattern: We respond immediately with the pending record and process
	// in the background. This is the async job pattern — the client can poll
	// GET /transcripts/:id to check status.
	job := worker.Job{
		ID:        t.ID,
		Type:      worker.JobTranscriptExtraction,
		CreatedAt: time.Now(),
	}

	if err := h.Worker.Submit(job); err != nil {
		// The transcript insert and outbox row committed together. Submit signals
		// a worker even if its idempotent payload refresh cannot reach PostgreSQL.
		log.Printf("Transcript %s queued durably; payload refresh failed and recovery was signaled: %v", t.ID, err)
	}

	// Return 202 Accepted — the work is happening in the background
	c.JSON(http.StatusAccepted, t)
}

// GetTranscript retrieves a single transcript by ID.
// GET /api/v1/transcripts/:id
func (h *Handler) GetTranscript(c *gin.Context) {
	id := c.Param("id")
	actor := getActorOwnership(c)

	t, err := h.DB.GetTranscriptForActor(c.Request.Context(), id, actor.UserID, actor.APIKeyID)
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error:   "not_found",
			Message: "Transcript not found",
			Code:    http.StatusNotFound,
		})
		return
	}

	c.JSON(http.StatusOK, t)
}

// ListTranscripts returns a paginated list of transcripts.
// GET /api/v1/transcripts?page=1&per_page=20&status=completed&search=golang
func (h *Handler) ListTranscripts(c *gin.Context) {
	// Go Pattern: ShouldBindQuery reads query parameters into a struct
	// using the `form` tags. Similar to Express's req.query but type-safe.
	var params models.TranscriptListParams
	if err := c.ShouldBindQuery(&params); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_params",
			Message: "Invalid query parameters: " + err.Error(),
			Code:    http.StatusBadRequest,
		})
		return
	}

	actor := getActorOwnership(c)
	params.UserID = actor.UserID
	params.APIKeyID = actor.APIKeyID

	transcripts, total, err := h.DB.ListTranscripts(c.Request.Context(), params)
	if err != nil {
		log.Printf("❌ Failed to list transcripts: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to list transcripts",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	// Ensure we return an empty array, not null
	if transcripts == nil {
		transcripts = []models.Transcript{}
	}

	perPage := params.PerPage
	if perPage < 1 {
		perPage = 20
	}
	page := params.Page
	if page < 1 {
		page = 1
	}

	c.JSON(http.StatusOK, models.PaginatedResponse[models.Transcript]{
		Data:       transcripts,
		Page:       page,
		PerPage:    perPage,
		TotalItems: total,
		TotalPages: int(math.Ceil(float64(total) / float64(perPage))),
	})
}

// CreateSummary generates an AI summary for a transcript.
// POST /api/v1/summaries
//
// Request body:
//
//	{
//	  "transcript_id": "uuid-here",
//	  "length": "medium",      // optional: short, medium, detailed
//	  "style": "bullet",       // optional: bullet, narrative, academic
//	  "model": "openai/gpt-4o" // optional: override default model
//	}
func (h *Handler) CreateSummary(c *gin.Context) {
	var req models.CreateSummaryRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_request",
			Message: "transcript_id is required",
			Code:    http.StatusBadRequest,
		})
		return
	}

	// Verify the transcript exists and is completed
	actor := getActorOwnership(c)
	t, err := h.DB.GetTranscriptForActor(c.Request.Context(), req.TranscriptID, actor.UserID, actor.APIKeyID)
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error:   "not_found",
			Message: "Transcript not found",
			Code:    http.StatusNotFound,
		})
		return
	}

	if t.Status != models.StatusCompleted {
		c.JSON(http.StatusConflict, models.ErrorResponse{
			Error:   "transcript_not_ready",
			Message: "Transcript is still being processed (status: " + string(t.Status) + ")",
			Code:    http.StatusConflict,
		})
		return
	}

	// Set defaults
	if req.Length == "" {
		req.Length = "medium"
	}
	if req.Style == "" {
		req.Style = "bullet"
	}
	validLengths := map[string]bool{"short": true, "medium": true, "detailed": true}
	validStyles := map[string]bool{"bullet": true, "narrative": true, "academic": true}
	if !validLengths[req.Length] || !validStyles[req.Style] {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_options",
			Message: "length must be short, medium, or detailed; style must be bullet, narrative, or academic",
			Code:    http.StatusBadRequest,
		})
		return
	}

	summaryRecord := &models.Summary{
		ID:           uuid.NewString(),
		TranscriptID: req.TranscriptID,
		ModelUsed:    req.Model,
		KeyPoints:    json.RawMessage(`[]`),
		Length:       req.Length,
		Style:        req.Style,
		ContentType:  req.ContentType,
		Status:       models.StatusPending,
	}
	if err := h.DB.CreateSummary(c.Request.Context(), summaryRecord); err != nil {
		log.Printf("failed to create summary job: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error: "database_error", Message: "Failed to create summary job", Code: http.StatusInternalServerError,
		})
		return
	}

	// Submit summary generation job
	payload, err := json.Marshal(worker.SummaryPayload{
		TranscriptID: req.TranscriptID,
		Model:        req.Model,
		Length:       req.Length,
		Style:        req.Style,
		ContentType:  req.ContentType,
		SummaryID:    summaryRecord.ID,
	})
	if err != nil {
		summaryRecord.Status = models.StatusFailed
		summaryRecord.ErrorMessage = "failed to prepare summary job"
		_ = h.DB.UpdateSummary(c.Request.Context(), summaryRecord)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error: "internal_error", Message: "Failed to prepare summary job", Code: http.StatusInternalServerError,
		})
		return
	}

	job := worker.Job{
		ID:        summaryRecord.ID,
		Type:      worker.JobSummaryGeneration,
		Payload:   payload,
		CreatedAt: time.Now(),
	}

	if err := h.Worker.Submit(job); err != nil {
		log.Printf("Summary %s queued durably; payload refresh failed and recovery was signaled: %v", summaryRecord.ID, err)
	}

	c.JSON(http.StatusAccepted, gin.H{
		"message":       "Summary generation started",
		"summary_id":    summaryRecord.ID,
		"transcript_id": req.TranscriptID,
		"length":        req.Length,
		"style":         req.Style,
	})
}

// GetSummariesByTranscript returns all summaries for a transcript.
// GET /api/v1/transcripts/:id/summaries
func (h *Handler) GetSummariesByTranscript(c *gin.Context) {
	transcriptID := c.Param("id")
	actor := getActorOwnership(c)
	if _, err := h.DB.GetTranscriptForActor(c.Request.Context(), transcriptID, actor.UserID, actor.APIKeyID); err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error:   "not_found",
			Message: "Transcript not found",
			Code:    http.StatusNotFound,
		})
		return
	}

	summaries, err := h.DB.GetSummariesByTranscript(c.Request.Context(), transcriptID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to fetch summaries",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	if summaries == nil {
		summaries = []models.Summary{}
	}

	c.JSON(http.StatusOK, summaries)
}

// DeleteTranscript removes a transcript by ID.
// DELETE /api/v1/transcripts/:id
func (h *Handler) DeleteTranscript(c *gin.Context) {
	id := c.Param("id")
	actor := getActorOwnership(c)
	if err := h.DB.DeleteTranscriptForActor(c.Request.Context(), id, actor.UserID, actor.APIKeyID); err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error:   "not_found",
			Message: "Transcript not found",
			Code:    http.StatusNotFound,
		})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "Transcript deleted"})
}
