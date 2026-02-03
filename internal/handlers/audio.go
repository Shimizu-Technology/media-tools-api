// audio.go handles audio transcription HTTP endpoints (MTA-16).
//
// POST /api/v1/audio/transcribe — Upload audio file for Whisper transcription
// GET  /api/v1/audio/transcriptions/:id — Get transcription result by ID
// GET  /api/v1/audio/transcriptions — List recent transcriptions
package handlers

import (
	"encoding/json"
	"fmt"
	"log"
	"math"
	"net/http"
	"path/filepath"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/audio"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/summary"
)

// allowedAudioTypes maps file extensions to MIME types for validation.
var allowedAudioTypes = map[string]bool{
	".mp3":  true,
	".wav":  true,
	".m4a":  true,
	".ogg":  true,
	".flac": true,
	".webm": true,
}

// maxAudioSize is the max upload size for audio files (25MB, Whisper API limit).
const maxAudioSize = 25 << 20 // 25MB

// TranscribeAudio handles audio file upload and transcription.
// POST /api/v1/audio/transcribe
//
// Accepts multipart file upload with field name "file".
// Supported formats: mp3, wav, m4a, ogg, flac, webm
//
// For configured Whisper API: processes synchronously and returns result.
// If OPENAI_API_KEY is not set, returns a helpful error message.
func (h *Handler) TranscribeAudio(c *gin.Context) {
	// Check if Whisper transcriber is configured
	if h.AudioTranscriber == nil || !h.AudioTranscriber.IsConfigured() {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{
			Error:   "service_unavailable",
			Message: "Audio transcription is not configured. Set the OPENAI_API_KEY environment variable to enable Whisper transcription.",
			Code:    http.StatusServiceUnavailable,
		})
		return
	}

	// Limit request body size
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, maxAudioSize)

	// Get the uploaded file
	file, header, err := c.Request.FormFile("file")
	if err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_request",
			Message: "No audio file provided. Upload a file with the field name 'file'. Max size: 25MB.",
			Code:    http.StatusBadRequest,
		})
		return
	}
	defer file.Close()

	// Validate file extension
	ext := strings.ToLower(filepath.Ext(header.Filename))
	if !allowedAudioTypes[ext] {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_file_type",
			Message: fmt.Sprintf("Unsupported audio format '%s'. Supported formats: mp3, wav, m4a, ogg, flac, webm", ext),
			Code:    http.StatusBadRequest,
		})
		return
	}

	// Generate a unique filename for storage reference
	storedFilename := uuid.New().String() + ext

	// Create a pending record in the database
	at := &models.AudioTranscription{
		Filename:     storedFilename,
		OriginalName: header.Filename,
		Status:       "processing",
	}

	if err := h.DB.CreateAudioTranscription(c.Request.Context(), at); err != nil {
		log.Printf("Failed to create audio transcription record: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to create transcription record",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	// Call the Whisper API
	result, err := h.AudioTranscriber.Transcribe(c.Request.Context(), file, header.Filename)
	if err != nil {
		log.Printf("Whisper transcription failed for %s: %v", header.Filename, err)
		// Update record as failed
		at.Status = "failed"
		at.ErrorMessage = err.Error()
		h.DB.UpdateAudioTranscription(c.Request.Context(), at)

		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "transcription_failed",
			Message: "Audio transcription failed: " + err.Error(),
			Code:    http.StatusInternalServerError,
		})
		return
	}

	// Update the record with results
	at.TranscriptText = result.Text
	at.Language = result.Language
	at.Duration = result.Duration
	at.WordCount = audio.CountWords(result.Text)
	at.Status = "completed"

	if err := h.DB.UpdateAudioTranscription(c.Request.Context(), at); err != nil {
		log.Printf("Failed to update audio transcription record: %v", err)
		// Still return the result even if DB update fails
	}

	c.JSON(http.StatusOK, at)
}

// GetAudioTranscription retrieves a single audio transcription by ID.
// GET /api/v1/audio/transcriptions/:id
func (h *Handler) GetAudioTranscription(c *gin.Context) {
	id := c.Param("id")

	at, err := h.DB.GetAudioTranscription(c.Request.Context(), id)
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error:   "not_found",
			Message: "Audio transcription not found",
			Code:    http.StatusNotFound,
		})
		return
	}

	c.JSON(http.StatusOK, at)
}

// ListAudioTranscriptions returns recent audio transcriptions.
// GET /api/v1/audio/transcriptions
func (h *Handler) ListAudioTranscriptions(c *gin.Context) {
	transcriptions, err := h.DB.ListAudioTranscriptions(c.Request.Context(), 50)
	if err != nil {
		log.Printf("Failed to list audio transcriptions: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to list audio transcriptions",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	if transcriptions == nil {
		transcriptions = []models.AudioTranscription{}
	}

	c.JSON(http.StatusOK, transcriptions)
}

// SummarizeAudio generates an AI summary for an audio transcription (MTA-22).
// POST /api/v1/audio/transcriptions/:id/summarize
//
// Request body (all optional):
//
//	{
//	  "content_type": "phone_call",  // phone_call, meeting, voice_memo, interview, lecture, general
//	  "model": "openai/gpt-4o",     // override AI model
//	  "length": "medium"             // short, medium, detailed
//	}
func (h *Handler) SummarizeAudio(c *gin.Context) {
	id := c.Param("id")

	// Check if summarizer is available
	if h.Summarizer == nil {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{
			Error:   "service_unavailable",
			Message: "AI summarization is not configured. Set the OPENROUTER_API_KEY environment variable.",
			Code:    http.StatusServiceUnavailable,
		})
		return
	}

	// Get the transcription
	at, err := h.DB.GetAudioTranscription(c.Request.Context(), id)
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error:   "not_found",
			Message: "Audio transcription not found",
			Code:    http.StatusNotFound,
		})
		return
	}

	if at.Status != "completed" {
		c.JSON(http.StatusConflict, models.ErrorResponse{
			Error:   "not_ready",
			Message: "Audio transcription is not completed yet (status: " + at.Status + ")",
			Code:    http.StatusConflict,
		})
		return
	}

	if at.TranscriptText == "" {
		c.JSON(http.StatusConflict, models.ErrorResponse{
			Error:   "empty_transcript",
			Message: "No transcript text available to summarize",
			Code:    http.StatusConflict,
		})
		return
	}

	// Parse request body
	var req models.SummarizeAudioRequest
	c.ShouldBindJSON(&req) // Optional body — ok if empty

	// Validate content type
	contentType := models.AudioContentType(req.ContentType)
	if req.ContentType == "" {
		contentType = models.ContentGeneral
	}
	if !models.ValidContentTypes[contentType] {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_content_type",
			Message: fmt.Sprintf("Invalid content_type '%s'. Valid types: general, phone_call, meeting, voice_memo, interview, lecture", req.ContentType),
			Code:    http.StatusBadRequest,
		})
		return
	}

	// Mark as processing
	at.SummaryStatus = "processing"
	at.ContentType = contentType
	h.DB.UpdateAudioSummary(c.Request.Context(), at)

	// Generate summary
	opts := summary.Options{
		Model:       req.Model,
		Length:      req.Length,
		ContentType: string(contentType),
	}

	result, err := h.Summarizer.SummarizeAudio(c.Request.Context(), at.TranscriptText, opts)
	if err != nil {
		log.Printf("Audio summary failed for %s: %v", id, err)
		at.SummaryStatus = "failed"
		h.DB.UpdateAudioSummary(c.Request.Context(), at)

		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "summary_failed",
			Message: "Failed to generate summary: " + err.Error(),
			Code:    http.StatusInternalServerError,
		})
		return
	}

	// Marshal arrays to JSON
	keyPointsJSON, _ := json.Marshal(result.KeyPoints)
	actionItemsJSON, _ := json.Marshal(result.ActionItems)
	decisionsJSON, _ := json.Marshal(result.Decisions)

	// Update record
	at.SummaryText = result.Summary
	at.KeyPoints = keyPointsJSON
	at.ActionItems = actionItemsJSON
	at.Decisions = decisionsJSON
	at.SummaryModel = result.Model
	at.SummaryStatus = "completed"
	at.ContentType = contentType

	if err := h.DB.UpdateAudioSummary(c.Request.Context(), at); err != nil {
		log.Printf("Failed to save audio summary for %s: %v", id, err)
	}

	c.JSON(http.StatusOK, at)
}

// SearchAudioTranscriptions searches audio transcriptions with full-text search (MTA-25).
// GET /api/v1/audio/transcriptions/search?q=keyword&content_type=phone_call&page=1&per_page=20
func (h *Handler) SearchAudioTranscriptions(c *gin.Context) {
	var params models.AudioSearchParams
	if err := c.ShouldBindQuery(&params); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_params",
			Message: "Invalid search parameters",
			Code:    http.StatusBadRequest,
		})
		return
	}

	results, total, err := h.DB.SearchAudioTranscriptions(c.Request.Context(), params)
	if err != nil {
		log.Printf("Audio search failed: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "search_failed",
			Message: "Search failed",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	if results == nil {
		results = []models.AudioTranscription{}
	}

	perPage := params.PerPage
	if perPage < 1 {
		perPage = 20
	}
	page := params.Page
	if page < 1 {
		page = 1
	}

	c.JSON(http.StatusOK, models.PaginatedResponse[models.AudioTranscription]{
		Data:       results,
		Page:       page,
		PerPage:    perPage,
		TotalItems: total,
		TotalPages: int(math.Ceil(float64(total) / float64(perPage))),
	})
}

// ExportAudioTranscription exports a transcription in the requested format (MTA-26).
// GET /api/v1/audio/transcriptions/:id/export?format=md
func (h *Handler) ExportAudioTranscription(c *gin.Context) {
	id := c.Param("id")
	format := c.DefaultQuery("format", "txt")

	at, err := h.DB.GetAudioTranscription(c.Request.Context(), id)
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error:   "not_found",
			Message: "Audio transcription not found",
			Code:    http.StatusNotFound,
		})
		return
	}

	baseName := strings.TrimSuffix(at.OriginalName, filepath.Ext(at.OriginalName))

	switch format {
	case "txt":
		c.Header("Content-Disposition", fmt.Sprintf("attachment; filename=%s_transcript.txt", baseName))
		c.Data(http.StatusOK, "text/plain", []byte(at.TranscriptText))

	case "md":
		md := buildMarkdownExport(at)
		c.Header("Content-Disposition", fmt.Sprintf("attachment; filename=%s_summary.md", baseName))
		c.Data(http.StatusOK, "text/markdown", []byte(md))

	case "json":
		c.Header("Content-Disposition", fmt.Sprintf("attachment; filename=%s_data.json", baseName))
		c.JSON(http.StatusOK, at)

	default:
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_format",
			Message: "Supported formats: txt, md, json",
			Code:    http.StatusBadRequest,
		})
	}
}

// buildMarkdownExport creates a formatted markdown document from an audio transcription (MTA-26).
func buildMarkdownExport(at *models.AudioTranscription) string {
	var sb strings.Builder

	sb.WriteString(fmt.Sprintf("# %s\n\n", at.OriginalName))
	sb.WriteString(fmt.Sprintf("**Date:** %s  \n", at.CreatedAt.Format("January 2, 2006 3:04 PM")))
	sb.WriteString(fmt.Sprintf("**Duration:** %.0f seconds  \n", at.Duration))
	sb.WriteString(fmt.Sprintf("**Language:** %s  \n", at.Language))
	sb.WriteString(fmt.Sprintf("**Words:** %d  \n\n", at.WordCount))

	if at.SummaryText != "" {
		sb.WriteString("## Summary\n\n")
		sb.WriteString(at.SummaryText)
		sb.WriteString("\n\n")

		var keyPoints []string
		json.Unmarshal(at.KeyPoints, &keyPoints)
		if len(keyPoints) > 0 {
			sb.WriteString("## Key Points\n\n")
			for _, kp := range keyPoints {
				sb.WriteString(fmt.Sprintf("- %s\n", kp))
			}
			sb.WriteString("\n")
		}

		var actionItems []string
		json.Unmarshal(at.ActionItems, &actionItems)
		if len(actionItems) > 0 {
			sb.WriteString("## Action Items\n\n")
			for _, ai := range actionItems {
				sb.WriteString(fmt.Sprintf("- [ ] %s\n", ai))
			}
			sb.WriteString("\n")
		}

		var decisions []string
		json.Unmarshal(at.Decisions, &decisions)
		if len(decisions) > 0 {
			sb.WriteString("## Decisions\n\n")
			for _, d := range decisions {
				sb.WriteString(fmt.Sprintf("- %s\n", d))
			}
			sb.WriteString("\n")
		}
	}

	sb.WriteString("## Full Transcript\n\n")
	sb.WriteString(at.TranscriptText)
	sb.WriteString("\n")

	return sb.String()
}
