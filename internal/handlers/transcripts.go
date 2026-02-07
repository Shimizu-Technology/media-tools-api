// transcripts.go handles all transcript-related HTTP endpoints.
package handlers

import (
	"context"
	"encoding/json"
	"log"
	"math"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/middleware"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/transcript"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/worker"
)

// CreateTranscript starts transcript extraction for a YouTube video.
// POST /api/v1/transcripts
//
// Request body:
//
//	{"url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ"}
//	  or
//	{"video_id": "dQw4w9WgXcQ"}
//
// Response: The created transcript record (status will be "pending").
// The actual extraction happens in the background via the worker pool.
func (h *Handler) CreateTranscript(c *gin.Context) {
	// Parse request body
	// Go Pattern: ShouldBindJSON reads the request body and validates it
	// using the `binding` tags on the struct. If validation fails, it returns
	// an error (unlike Ruby's strong_params which silently ignores bad data).
	var req models.CreateTranscriptRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_request",
			Message: "Provide either 'url' or 'video_id' in the request body",
			Code:    http.StatusBadRequest,
		})
		return
	}

	// Parse the YouTube URL to extract the video ID
	var youtubeURL, videoID string
	var err error

	if req.URL != "" {
		youtubeURL, videoID, err = transcript.ParseYouTubeURL(req.URL)
	} else {
		youtubeURL, videoID, err = transcript.ParseYouTubeURL(req.VideoID)
	}

	if err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_url",
			Message: err.Error(),
			Code:    http.StatusBadRequest,
		})
		return
	}

	// Check if we already have a transcript for this video
	existing, _ := h.DB.GetTranscriptByYouTubeID(c.Request.Context(), videoID)
	if existing != nil && existing.Status == models.StatusCompleted {
		// Return the existing transcript instead of re-extracting
		c.JSON(http.StatusOK, existing)
		return
	}

	// Get the API key from context (set by auth middleware)
	var apiKeyID *string
	if apiKey := middleware.GetAPIKey(c); apiKey != nil {
		apiKeyID = &apiKey.ID
	}

	// Create a new transcript record with "pending" status
	t := &models.Transcript{
		YouTubeURL: youtubeURL,
		YouTubeID:  videoID,
		Status:     models.StatusPending,
		APIKeyID:   apiKeyID,
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
		if h.isOwnerRequest(c) {
			ctx, cancel := context.WithTimeout(c.Request.Context(), 15*time.Second)
			defer cancel()
			if err := h.Worker.SubmitBlocking(ctx, job); err == nil {
				c.JSON(http.StatusAccepted, t)
				return
			}
		}
		log.Printf("⚠️  Failed to queue extraction job: %v", err)
		// The transcript record exists but extraction didn't start.
		// The client can retry or the transcript will stay "pending".
	}

	// Return 202 Accepted — the work is happening in the background
	c.JSON(http.StatusAccepted, t)
}

// GetTranscript retrieves a single transcript by ID.
// GET /api/v1/transcripts/:id
func (h *Handler) GetTranscript(c *gin.Context) {
	id := c.Param("id")

	t, err := h.DB.GetTranscript(c.Request.Context(), id)
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

	// Filter by the authenticated API key
	if apiKey := middleware.GetAPIKey(c); apiKey != nil {
		params.APIKeyID = &apiKey.ID
	}

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
	t, err := h.DB.GetTranscript(c.Request.Context(), req.TranscriptID)
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

	// Submit summary generation job
	payload, _ := json.Marshal(worker.SummaryPayload{
		TranscriptID: req.TranscriptID,
		Model:        req.Model,
		Length:        req.Length,
		Style:        req.Style,
	})

	job := worker.Job{
		ID:        req.TranscriptID, // Use transcript ID as job reference
		Type:      worker.JobSummaryGeneration,
		Payload:   payload,
		CreatedAt: time.Now(),
	}

	if err := h.Worker.Submit(job); err != nil {
		if h.isOwnerRequest(c) {
			ctx, cancel := context.WithTimeout(c.Request.Context(), 15*time.Second)
			defer cancel()
			if err := h.Worker.SubmitBlocking(ctx, job); err == nil {
				c.JSON(http.StatusAccepted, gin.H{
					"message":       "Summary generation started",
					"transcript_id": req.TranscriptID,
					"length":        req.Length,
					"style":         req.Style,
				})
				return
			}
		}
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{
			Error:   "queue_full",
			Message: "Job queue is full, try again later",
			Code:    http.StatusServiceUnavailable,
		})
		return
	}

	c.JSON(http.StatusAccepted, gin.H{
		"message":       "Summary generation started",
		"transcript_id": req.TranscriptID,
		"length":        req.Length,
		"style":         req.Style,
	})
}

// GetSummariesByTranscript returns all summaries for a transcript.
// GET /api/v1/transcripts/:id/summaries
func (h *Handler) GetSummariesByTranscript(c *gin.Context) {
	transcriptID := c.Param("id")

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

	// Verify ownership: only delete if it belongs to the authenticated API key
	if apiKey := middleware.GetAPIKey(c); apiKey != nil {
		t, err := h.DB.GetTranscript(c.Request.Context(), id)
		if err != nil {
			c.JSON(http.StatusNotFound, models.ErrorResponse{
				Error:   "not_found",
				Message: "Transcript not found",
				Code:    http.StatusNotFound,
			})
			return
		}

		// Check ownership - only allow deletion if the API key owns this transcript
		if t.APIKeyID != nil && *t.APIKeyID != apiKey.ID {
			c.JSON(http.StatusForbidden, models.ErrorResponse{
				Error:   "forbidden",
				Message: "You can only delete your own transcripts",
				Code:    http.StatusForbidden,
			})
			return
		}
	}

	if err := h.DB.DeleteTranscript(c.Request.Context(), id); err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error:   "not_found",
			Message: "Transcript not found",
			Code:    http.StatusNotFound,
		})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "Transcript deleted"})
}
