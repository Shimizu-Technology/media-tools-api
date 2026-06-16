// audio.go handles recording transcription HTTP endpoints (MTA-16).
//
// POST /api/v1/audio/transcribe — Upload audio or recording file for transcription
// GET  /api/v1/audio/transcriptions/:id — Get transcription result by ID
// GET  /api/v1/audio/transcriptions — List recent transcriptions
package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/summary"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/worker"
)

const supportedTranscriptionUploadFormats = "mp3, wav, m4a, mp4, ogg, flac, webm"

// supportedTranscriptionUploadTypes maps upload extensions accepted by the app.
//
// Phase 1 Zoom support adds `.mp4` so users can upload Zoom cloud/computer
// recordings while the worker continues to normalize them into audio.
var supportedTranscriptionUploadTypes = map[string]bool{
	".mp3":  true,
	".wav":  true,
	".m4a":  true,
	".mp4":  true,
	".ogg":  true,
	".flac": true,
	".webm": true,
}

func isSupportedTranscriptionUploadExt(ext string) bool {
	return supportedTranscriptionUploadTypes[strings.ToLower(ext)]
}

// maxAudioSize is the max upload size for audio and recording files.
// 2GB keeps room for very long recordings while chunking handles Whisper limits.
const maxAudioSize = 2 << 30

type AudioUploadPresignRequest struct {
	Filename    string `json:"filename" binding:"required"`
	ContentType string `json:"content_type"`
	SizeBytes   int64  `json:"size_bytes"`
}

type AudioUploadCompleteRequest struct {
	ObjectKey    string `json:"object_key" binding:"required"`
	OriginalName string `json:"original_name" binding:"required"`
	SizeBytes    int64  `json:"size_bytes"`
}

// TranscribeAudio handles audio/recording file upload and queues transcription job.
// POST /api/v1/audio/transcribe
//
// Accepts multipart file upload with field name "file".
// Supported formats: mp3, wav, m4a, mp4, ogg, flac, webm
//
// Returns 202 Accepted immediately with the transcription record.
// Frontend should poll GET /api/v1/audio/transcriptions/:id for completion.
// This async pattern handles long audio files without timeout issues.
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

	actor := getActorOwnership(c)
	if !actor.IsAuthenticated() {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{
			Error:   "unauthorized",
			Message: "Authentication required",
			Code:    http.StatusUnauthorized,
		})
		return
	}

	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, maxAudioSize)

	// Get the uploaded file
	file, header, err := c.Request.FormFile("file")
	if err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_request",
			Message: "No file provided. Upload an audio or recording file with the field name 'file'. Max size: 2GB.",
			Code:    http.StatusBadRequest,
		})
		return
	}
	defer file.Close()

	// Check file size (25MB limit for Whisper API)
	if header.Size > maxAudioSize {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "file_too_large",
			Message: fmt.Sprintf("File size (%.1f MB) exceeds maximum (2048 MB).", float64(header.Size)/(1024*1024)),
			Code:    http.StatusBadRequest,
		})
		return
	}

	// Validate file extension
	ext := strings.ToLower(filepath.Ext(header.Filename))
	if !isSupportedTranscriptionUploadExt(ext) {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_file_type",
			Message: fmt.Sprintf("Unsupported upload format '%s'. Supported formats: %s", ext, supportedTranscriptionUploadFormats),
			Code:    http.StatusBadRequest,
		})
		return
	}

	// Generate unique identifiers
	storedFilename := uuid.New().String() + ext

	// Save the uploaded file to a temp location for async processing
	tempDir := os.TempDir()
	tempFilePath := filepath.Join(tempDir, storedFilename)

	tempFile, err := os.Create(tempFilePath)
	if err != nil {
		log.Printf("Failed to create temp file: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "server_error",
			Message: "Failed to process uploaded file",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	if _, err := io.Copy(tempFile, file); err != nil {
		tempFile.Close()
		os.Remove(tempFilePath)
		log.Printf("Failed to save temp file: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "server_error",
			Message: "Failed to save uploaded file",
			Code:    http.StatusInternalServerError,
		})
		return
	}
	tempFile.Close()

	audioS3Status := "not_configured"
	audioS3Key := ""
	audioS3Size := int64(0)
	if h.AudioStorage != nil && h.AudioStorage.IsConfigured() {
		audioS3Key = h.AudioStorage.BuildKey(storedFilename)
		uploadCtx, cancel := context.WithTimeout(c.Request.Context(), 90*time.Second)
		defer cancel()
		if err := h.AudioStorage.UploadFile(uploadCtx, tempFilePath, audioS3Key, header.Header.Get("Content-Type")); err != nil {
			os.Remove(tempFilePath)
			log.Printf("Failed to persist audio to S3: %v", err)
			c.JSON(http.StatusInternalServerError, models.ErrorResponse{
				Error:   "storage_error",
				Message: "Failed to persist recording before transcription",
				Code:    http.StatusInternalServerError,
			})
			return
		}
		audioS3Status = "uploaded"
		audioS3Size = header.Size
	}

	// Create a pending record in the database
	at := &models.AudioTranscription{
		Filename:           storedFilename,
		OriginalName:       header.Filename,
		Status:             "pending",
		AudioS3Key:         audioS3Key,
		AudioS3Status:      audioS3Status,
		AudioS3Size:        audioS3Size,
		ProcessingStage:    "queued",
		ProcessingProgress: 0,
		UserID:             actor.UserID,
		APIKeyID:           actor.APIKeyID,
	}

	if err := h.DB.CreateAudioTranscription(c.Request.Context(), at); err != nil {
		os.Remove(tempFilePath) // Clean up temp file on error
		log.Printf("Failed to create audio transcription record: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to create transcription record",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	// Create the job payload
	payload := worker.AudioPayload{
		AudioID:      at.ID,
		TempFilePath: tempFilePath,
		AudioS3Key:   at.AudioS3Key,
		OriginalName: header.Filename,
	}

	payloadJSON, err := json.Marshal(payload)
	if err != nil {
		os.Remove(tempFilePath)
		log.Printf("Failed to marshal audio payload: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "server_error",
			Message: "Failed to queue transcription job",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	// Submit the job to the worker pool
	job := worker.Job{
		ID:        at.ID,
		Type:      worker.JobAudioTranscription,
		Payload:   payloadJSON,
		CreatedAt: time.Now(),
	}

	if err := h.Worker.Submit(job); err != nil {
		if h.isOwnerRequest(c) {
			ctx, cancel := context.WithTimeout(c.Request.Context(), 15*time.Second)
			defer cancel()
			if err := h.Worker.SubmitBlocking(ctx, job); err == nil {
				log.Printf("📤 Audio transcription job queued (blocking): %s (%s, %.1f MB)",
					at.ID, header.Filename, float64(header.Size)/(1024*1024))
				c.JSON(http.StatusAccepted, at)
				return
			}
		}

		os.Remove(tempFilePath)
		at.Status = "failed"
		at.ErrorMessage = "Job queue is full, please try again later"
		h.DB.UpdateAudioTranscription(c.Request.Context(), at)

		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{
			Error:   "queue_full",
			Message: "Server is busy. Please try again in a moment.",
			Code:    http.StatusServiceUnavailable,
		})
		return
	}

	log.Printf("📤 Audio transcription job queued: %s (%s, %.1f MB)",
		at.ID, header.Filename, float64(header.Size)/(1024*1024))

	// Return 202 Accepted — frontend should poll for completion
	c.JSON(http.StatusAccepted, at)
}

// PresignAudioUpload returns a short-lived S3 URL for direct browser upload.
// POST /api/v1/audio/uploads/presign
func (h *Handler) PresignAudioUpload(c *gin.Context) {
	actor := getActorOwnership(c)
	if !actor.IsAuthenticated() {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{
			Error:   "unauthorized",
			Message: "Authentication required",
			Code:    http.StatusUnauthorized,
		})
		return
	}

	if h.AudioStorage == nil || !h.AudioStorage.IsConfigured() {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{
			Error:   "storage_unavailable",
			Message: "Audio storage is not configured.",
			Code:    http.StatusServiceUnavailable,
		})
		return
	}

	var req AudioUploadPresignRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_request",
			Message: "filename is required",
			Code:    http.StatusBadRequest,
		})
		return
	}
	if req.SizeBytes <= 0 || req.SizeBytes > maxAudioSize {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "file_too_large",
			Message: "size_bytes must be between 1 byte and 2GB",
			Code:    http.StatusBadRequest,
		})
		return
	}

	ext := strings.ToLower(filepath.Ext(req.Filename))
	if !isSupportedTranscriptionUploadExt(ext) {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_file_type",
			Message: fmt.Sprintf("Unsupported upload format '%s'. Supported formats: %s", ext, supportedTranscriptionUploadFormats),
			Code:    http.StatusBadRequest,
		})
		return
	}

	storedFilename := uuid.New().String() + ext
	objectKey := h.AudioStorage.BuildKey(storedFilename)
	contentType := req.ContentType
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	putURL, err := h.AudioStorage.PresignedPutURL(objectKey, contentType)
	if err != nil {
		c.JSON(http.StatusBadGateway, models.ErrorResponse{
			Error:   "storage_error",
			Message: "Failed to generate upload URL",
			Code:    http.StatusBadGateway,
		})
		return
	}

	session := &models.AudioUploadSession{
		ObjectKey:    objectKey,
		OriginalName: filepath.Base(req.Filename),
		ContentType:  contentType,
		SizeBytes:    req.SizeBytes,
		UserID:       actor.UserID,
		APIKeyID:     actor.APIKeyID,
		ExpiresAt:    time.Now().UTC().Add(time.Hour),
	}
	if err := h.DB.CreateAudioUploadSession(c.Request.Context(), session); err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to create upload session",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"upload_url":  putURL,
		"object_key":  objectKey,
		"stored_name": storedFilename,
		"upload_id":   session.ID,
		"expires_in":  "60m",
	})
}

// CompleteAudioUpload creates a transcription job after direct S3 upload.
// POST /api/v1/audio/uploads/complete
func (h *Handler) CompleteAudioUpload(c *gin.Context) {
	actor := getActorOwnership(c)
	if !actor.IsAuthenticated() {
		c.JSON(http.StatusUnauthorized, models.ErrorResponse{
			Error:   "unauthorized",
			Message: "Authentication required",
			Code:    http.StatusUnauthorized,
		})
		return
	}

	if h.AudioStorage == nil || !h.AudioStorage.IsConfigured() {
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{
			Error:   "storage_unavailable",
			Message: "Audio storage is not configured.",
			Code:    http.StatusServiceUnavailable,
		})
		return
	}

	var req AudioUploadCompleteRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_request",
			Message: "object_key and original_name are required",
			Code:    http.StatusBadRequest,
		})
		return
	}

	ext := strings.ToLower(filepath.Ext(req.OriginalName))
	if !isSupportedTranscriptionUploadExt(ext) {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_file_type",
			Message: fmt.Sprintf("Unsupported upload format '%s'. Supported formats: %s", ext, supportedTranscriptionUploadFormats),
			Code:    http.StatusBadRequest,
		})
		return
	}
	if req.SizeBytes <= 0 || req.SizeBytes > maxAudioSize {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "file_too_large",
			Message: "size_bytes must be between 1 byte and 2GB",
			Code:    http.StatusBadRequest,
		})
		return
	}

	session, err := h.DB.GetAudioUploadSessionForActor(c.Request.Context(), req.ObjectKey, actor.UserID, actor.APIKeyID)
	if err != nil {
		c.JSON(http.StatusForbidden, models.ErrorResponse{
			Error:   "forbidden",
			Message: "Upload session not found, expired, or not owned by you",
			Code:    http.StatusForbidden,
		})
		return
	}
	if session.OriginalName != filepath.Base(req.OriginalName) || session.SizeBytes != req.SizeBytes {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_upload_completion",
			Message: "Upload completion does not match the presigned upload session",
			Code:    http.StatusBadRequest,
		})
		return
	}
	objectInfo, err := h.AudioStorage.HeadObject(c.Request.Context(), req.ObjectKey)
	if err != nil {
		c.JSON(http.StatusBadGateway, models.ErrorResponse{
			Error:   "storage_error",
			Message: "Uploaded object could not be verified",
			Code:    http.StatusBadGateway,
		})
		return
	}
	if objectInfo.Size != req.SizeBytes {
		if deleteErr := h.AudioStorage.DeleteObject(c.Request.Context(), req.ObjectKey); deleteErr != nil {
			log.Printf("⚠️  Failed to delete rejected oversized upload %s: %v", req.ObjectKey, deleteErr)
		}
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_upload_size",
			Message: "Uploaded object size does not match the presigned upload",
			Code:    http.StatusBadRequest,
		})
		return
	}

	at := &models.AudioTranscription{
		Filename:           filepath.Base(req.ObjectKey),
		OriginalName:       req.OriginalName,
		Status:             "pending",
		AudioS3Key:         req.ObjectKey,
		AudioS3Status:      "uploaded",
		AudioS3Size:        req.SizeBytes,
		ProcessingStage:    "queued",
		ProcessingProgress: 0,
		UserID:             actor.UserID,
		APIKeyID:           actor.APIKeyID,
	}
	if err := h.DB.CompleteAudioUploadAndCreateTranscription(c.Request.Context(), session.ID, at); err != nil {
		if errors.Is(err, database.ErrAudioUploadSessionNotPending) {
			c.JSON(http.StatusConflict, models.ErrorResponse{
				Error:   "upload_already_completed",
				Message: "Upload session has already been completed",
				Code:    http.StatusConflict,
			})
		} else {
			c.JSON(http.StatusInternalServerError, models.ErrorResponse{
				Error:   "database_error",
				Message: "Failed to create transcription record",
				Code:    http.StatusInternalServerError,
			})
		}
		return
	}

	payload := worker.AudioPayload{
		AudioID:      at.ID,
		AudioS3Key:   req.ObjectKey,
		OriginalName: req.OriginalName,
	}
	payloadJSON, err := json.Marshal(payload)
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "server_error",
			Message: "Failed to queue transcription job",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	job := worker.Job{
		ID:        at.ID,
		Type:      worker.JobAudioTranscription,
		Payload:   payloadJSON,
		CreatedAt: time.Now(),
	}

	if err := h.Worker.Submit(job); err != nil {
		if h.isOwnerRequest(c) {
			ctx, cancel := context.WithTimeout(c.Request.Context(), 15*time.Second)
			defer cancel()
			if err := h.Worker.SubmitBlocking(ctx, job); err == nil {
				c.JSON(http.StatusAccepted, at)
				return
			}
		}
		at.Status = "failed"
		at.ErrorMessage = "Job queue is full, please try again later"
		at.ProcessingStage = "failed"
		at.ProcessingProgress = 100
		_ = h.DB.UpdateAudioTranscription(c.Request.Context(), at)

		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{
			Error:   "queue_full",
			Message: "Server is busy. Please try again in a moment.",
			Code:    http.StatusServiceUnavailable,
		})
		return
	}

	c.JSON(http.StatusAccepted, at)
}

// GetAudioTranscription retrieves a single audio transcription by ID.
// GET /api/v1/audio/transcriptions/:id
func (h *Handler) GetAudioTranscription(c *gin.Context) {
	id := c.Param("id")
	actor := getActorOwnership(c)

	at, err := h.DB.GetAudioTranscriptionForActor(c.Request.Context(), id, actor.UserID, actor.APIKeyID)
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

// RenameAudioTranscription updates the display name for a recording.
// PATCH /api/v1/audio/transcriptions/:id
func (h *Handler) RenameAudioTranscription(c *gin.Context) {
	id := c.Param("id")
	actor := getActorOwnership(c)

	var req models.RenameAudioTranscriptionRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_request",
			Message: "name is required",
			Code:    http.StatusBadRequest,
		})
		return
	}
	name := strings.TrimSpace(req.Name)
	if name == "" || len(name) > 500 {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_name",
			Message: "name must be between 1 and 500 characters",
			Code:    http.StatusBadRequest,
		})
		return
	}

	at, err := h.DB.RenameAudioTranscriptionForActor(c.Request.Context(), id, actor.UserID, actor.APIKeyID, name)
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

// RetryAudioTranscription re-queues a failed or completed transcription from durable S3 audio.
// This powers both "retry failed job" and "re-transcribe bad transcript" UX.
// POST /api/v1/audio/transcriptions/:id/retry
func (h *Handler) RetryAudioTranscription(c *gin.Context) {
	id := c.Param("id")

	actor := getActorOwnership(c)
	at, err := h.DB.GetAudioTranscriptionForActor(c.Request.Context(), id, actor.UserID, actor.APIKeyID)
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error:   "not_found",
			Message: "Audio transcription not found",
			Code:    http.StatusNotFound,
		})
		return
	}

	if at.Status == "pending" || at.Status == "processing" {
		c.JSON(http.StatusConflict, models.ErrorResponse{
			Error:   "already_processing",
			Message: "This recording is already being transcribed.",
			Code:    http.StatusConflict,
		})
		return
	}

	if h.AudioStorage == nil || !h.AudioStorage.IsConfigured() || at.AudioS3Key == "" {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "storage_unavailable",
			Message: "Durable audio storage is not available for this transcription",
			Code:    http.StatusBadRequest,
		})
		return
	}

	ext := filepath.Ext(at.Filename)
	if ext == "" {
		ext = ".webm"
	}
	tempFilePath := filepath.Join(os.TempDir(), uuid.New().String()+ext)
	downloadCtx, cancel := context.WithTimeout(c.Request.Context(), 90*time.Second)
	defer cancel()
	if err := h.AudioStorage.DownloadFile(downloadCtx, at.AudioS3Key, tempFilePath); err != nil {
		log.Printf("Failed to download audio from S3 for retry: %v", err)
		c.JSON(http.StatusBadGateway, models.ErrorResponse{
			Error:   "storage_error",
			Message: "Failed to fetch stored audio for retry",
			Code:    http.StatusBadGateway,
		})
		return
	}

	at.Duration = 0
	at.Language = ""
	at.TranscriptText = ""
	at.WordCount = 0
	at.Status = "pending"
	at.ErrorMessage = ""
	at.ProcessingStage = "queued"
	at.ProcessingProgress = 0
	at.SummaryText = ""
	at.KeyPoints = json.RawMessage("[]")
	at.ActionItems = json.RawMessage("[]")
	at.Decisions = json.RawMessage("[]")
	at.SummaryModel = ""
	at.SummaryStatus = "none"
	if err := h.DB.UpdateAudioTranscription(c.Request.Context(), at); err != nil {
		os.Remove(tempFilePath)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to prepare retry",
			Code:    http.StatusInternalServerError,
		})
		return
	}
	if err := h.DB.UpdateAudioSummary(c.Request.Context(), at); err != nil {
		os.Remove(tempFilePath)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to reset previous summary",
			Code:    http.StatusInternalServerError,
		})
		return
	}
	if err := h.DB.DeleteChatSessionForActor(c.Request.Context(), "audio", at.ID, actor.UserID, actor.APIKeyID); err != nil {
		log.Printf("Warning: failed to clear stale audio chat session for %s before re-transcribe: %v", at.ID, err)
	}
	payload := worker.AudioPayload{
		AudioID:      at.ID,
		TempFilePath: tempFilePath,
		AudioS3Key:   at.AudioS3Key,
		OriginalName: at.OriginalName,
	}
	payloadJSON, err := json.Marshal(payload)
	if err != nil {
		os.Remove(tempFilePath)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "server_error",
			Message: "Failed to queue retry job",
			Code:    http.StatusInternalServerError,
		})
		return
	}
	job := worker.Job{
		ID:        at.ID,
		Type:      worker.JobAudioTranscription,
		Payload:   payloadJSON,
		CreatedAt: time.Now(),
	}
	if err := h.Worker.Submit(job); err != nil {
		if h.isOwnerRequest(c) {
			ctx, cancel := context.WithTimeout(c.Request.Context(), 15*time.Second)
			defer cancel()
			if err := h.Worker.SubmitBlocking(ctx, job); err == nil {
				c.JSON(http.StatusAccepted, at)
				return
			}
		}
		os.Remove(tempFilePath)
		at.Status = "failed"
		at.ErrorMessage = "Retry queue is full, please try again later"
		_ = h.DB.UpdateAudioTranscription(c.Request.Context(), at)
		c.JSON(http.StatusServiceUnavailable, models.ErrorResponse{
			Error:   "queue_full",
			Message: "Server is busy. Please try again in a moment.",
			Code:    http.StatusServiceUnavailable,
		})
		return
	}

	c.JSON(http.StatusAccepted, at)
}

// CancelAudioTranscription stops the UI from polling a pending/processing job.
// It marks the record failed so the user can retry from durable audio or start over.
// POST /api/v1/audio/transcriptions/:id/cancel
func (h *Handler) CancelAudioTranscription(c *gin.Context) {
	id := c.Param("id")

	actor := getActorOwnership(c)
	at, err := h.DB.CancelAudioTranscriptionForActor(
		c.Request.Context(),
		id,
		actor.UserID,
		actor.APIKeyID,
		"Processing was stopped by the user.",
	)
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error:   "not_found",
			Message: "Audio transcription not found",
			Code:    http.StatusNotFound,
		})
		return
	}

	if at.Status == "completed" {
		c.JSON(http.StatusConflict, models.ErrorResponse{
			Error:   "already_completed",
			Message: "Completed transcriptions cannot be canceled.",
			Code:    http.StatusConflict,
		})
		return
	}

	c.JSON(http.StatusOK, at)
}

// GetAudioPlaybackURL returns a short-lived URL for replaying the stored recording.
// GET /api/v1/audio/transcriptions/:id/audio
func (h *Handler) GetAudioPlaybackURL(c *gin.Context) {
	id := c.Param("id")

	actor := getActorOwnership(c)
	at, err := h.DB.GetAudioTranscriptionForActor(c.Request.Context(), id, actor.UserID, actor.APIKeyID)
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error:   "not_found",
			Message: "Audio transcription not found",
			Code:    http.StatusNotFound,
		})
		return
	}

	if h.AudioStorage == nil || !h.AudioStorage.IsConfigured() || at.AudioS3Key == "" {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "storage_unavailable",
			Message: "Audio file is not available for playback",
			Code:    http.StatusBadRequest,
		})
		return
	}

	url, err := h.AudioStorage.PresignedGetURL(at.AudioS3Key)
	if err != nil {
		c.JSON(http.StatusBadGateway, models.ErrorResponse{
			Error:   "storage_error",
			Message: "Failed to create playback URL",
			Code:    http.StatusBadGateway,
		})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"url":        url,
		"expires_in": "60m",
	})
}

// ListAudioTranscriptions returns recent audio transcriptions for the authenticated API key.
// GET /api/v1/audio/transcriptions
func (h *Handler) ListAudioTranscriptions(c *gin.Context) {
	actor := getActorOwnership(c)

	transcriptions, err := h.DB.ListAudioTranscriptions(c.Request.Context(), 50, actor.UserID, actor.APIKeyID)
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
	actor := getActorOwnership(c)
	at, err := h.DB.GetAudioTranscriptionForActor(c.Request.Context(), id, actor.UserID, actor.APIKeyID)
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
	keyPointsJSON, err := json.Marshal(result.KeyPoints)
	if err != nil {
		log.Printf("Failed to marshal key points for %s: %v", id, err)
		keyPointsJSON = []byte("[]")
	}
	actionItemsJSON, err := json.Marshal(result.ActionItems)
	if err != nil {
		log.Printf("Failed to marshal action items for %s: %v", id, err)
		actionItemsJSON = []byte("[]")
	}
	decisionsJSON, err := json.Marshal(result.Decisions)
	if err != nil {
		log.Printf("Failed to marshal decisions for %s: %v", id, err)
		decisionsJSON = []byte("[]")
	}

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

	actor := getActorOwnership(c)
	results, total, err := h.DB.SearchAudioTranscriptions(c.Request.Context(), params, actor.UserID, actor.APIKeyID)
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

	actor := getActorOwnership(c)
	at, err := h.DB.GetAudioTranscriptionForActor(c.Request.Context(), id, actor.UserID, actor.APIKeyID)
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error:   "not_found",
			Message: "Audio transcription not found",
			Code:    http.StatusNotFound,
		})
		return
	}

	baseName := sanitizeFilename(strings.TrimSuffix(at.OriginalName, filepath.Ext(at.OriginalName)))
	if baseName == "" {
		baseName = "audio-transcription"
	}

	switch format {
	case "txt":
		c.Header("Content-Disposition", fmt.Sprintf(`attachment; filename="%s_transcript.txt"`, baseName))
		c.Data(http.StatusOK, "text/plain", []byte(at.TranscriptText))

	case "md":
		md := buildMarkdownExport(at)
		c.Header("Content-Disposition", fmt.Sprintf(`attachment; filename="%s_summary.md"`, baseName))
		c.Data(http.StatusOK, "text/markdown", []byte(md))

	case "json":
		c.Header("Content-Disposition", fmt.Sprintf(`attachment; filename="%s_data.json"`, baseName))
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

// GetAudioOpsHealth returns operational metrics for audio processing.
// GET /api/v1/ops/audio/health
func (h *Handler) GetAudioOpsHealth(c *gin.Context) {
	if !h.isOwnerRequest(c) {
		c.JSON(http.StatusForbidden, models.ErrorResponse{
			Error:   "forbidden",
			Message: "Owner key required for ops metrics",
			Code:    http.StatusForbidden,
		})
		return
	}

	type stats struct {
		Pending    int `db:"pending"`
		Processing int `db:"processing"`
		Failed     int `db:"failed"`
		Completed  int `db:"completed"`
		Last24h    int `db:"last_24h"`
	}
	var s stats
	err := h.DB.GetContext(c.Request.Context(), &s, `
		SELECT
			COUNT(*) FILTER (WHERE status = 'pending') AS pending,
			COUNT(*) FILTER (WHERE status = 'processing') AS processing,
			COUNT(*) FILTER (WHERE status = 'failed') AS failed,
			COUNT(*) FILTER (WHERE status = 'completed') AS completed,
			COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '24 hours') AS last_24h
		FROM audio_transcriptions
	`)
	if err != nil {
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to load ops metrics",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"queue_size":      h.Worker.QueueSize(),
		"worker_count":    h.Worker.WorkerCount(),
		"pending":         s.Pending,
		"processing":      s.Processing,
		"failed":          s.Failed,
		"completed":       s.Completed,
		"created_last24h": s.Last24h,
		"timestamp":       time.Now().UTC(),
	})
}

// DeleteAudioTranscription removes an audio transcription by ID.
// DELETE /api/v1/audio/transcriptions/:id
func (h *Handler) DeleteAudioTranscription(c *gin.Context) {
	id := c.Param("id")
	actor := getActorOwnership(c)

	at, err := h.DB.GetAudioTranscriptionForActor(c.Request.Context(), id, actor.UserID, actor.APIKeyID)
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error:   "not_found",
			Message: "Audio transcription not found",
			Code:    http.StatusNotFound,
		})
		return
	}

	if h.AudioStorage != nil && h.AudioStorage.IsConfigured() && at.AudioS3Key != "" {
		if err := h.AudioStorage.DeleteObject(c.Request.Context(), at.AudioS3Key); err != nil {
			log.Printf("Warning: failed to delete S3 audio object %s: %v", at.AudioS3Key, err)
		} else {
			log.Printf("Deleted S3 audio object: %s", at.AudioS3Key)
		}
	}

	if err := h.DB.DeleteAudioTranscriptionForActor(c.Request.Context(), id, actor.UserID, actor.APIKeyID); err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error:   "not_found",
			Message: "Audio transcription not found",
			Code:    http.StatusNotFound,
		})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "Audio transcription deleted"})
}
