// audio.go handles audio transcription HTTP endpoints (MTA-16).
//
// POST /api/v1/audio/transcribe — Upload audio file for Whisper transcription
// GET  /api/v1/audio/transcriptions/:id — Get transcription result by ID
// GET  /api/v1/audio/transcriptions — List recent transcriptions
package handlers

import (
	"fmt"
	"log"
	"net/http"
	"path/filepath"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/audio"
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
