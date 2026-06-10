// batches.go handles batch transcript processing endpoints (MTA-8).
//
// Batch processing lets users submit multiple video URLs at once.
// Each URL becomes its own transcript record, all linked to a single batch.
// The batch provides aggregate status tracking.
package handlers

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/transcript"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/worker"
)

// CreateBatch starts transcript extraction for multiple video URLs.
// POST /api/v1/transcripts/batch
//
// Request body:
//
//	{"urls": ["https://youtube.com/watch?v=abc", "https://youtube.com/watch?v=def"]}
//
// Response: The created batch with all transcript records.
//
// Go Pattern: This handler follows the same pattern as CreateTranscript but
// in a loop. We validate ALL URLs first before creating any records — this
// gives the user immediate feedback if any URL is invalid, rather than
// discovering it mid-processing.
func (h *Handler) CreateBatch(c *gin.Context) {
	var req models.CreateBatchRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "invalid_request",
			Message: "Provide 'urls' array with 1-10 video URLs",
			Code:    http.StatusBadRequest,
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

	// Enforce the 10-URL limit explicitly (belt + suspenders with the binding tag)
	if len(req.URLs) > 10 {
		c.JSON(http.StatusBadRequest, models.ErrorResponse{
			Error:   "too_many_urls",
			Message: "Maximum 10 URLs per batch request",
			Code:    http.StatusBadRequest,
		})
		return
	}

	// Step 1: Validate ALL URLs before creating any records.
	// Go Pattern: "Validate early, fail fast." If URL #5 is invalid,
	// we don't want to have already created records for URLs #1-4.
	type parsedURL struct {
		fullURL string
		videoID string
	}
	parsed := make([]parsedURL, 0, len(req.URLs))

	for i, rawURL := range req.URLs {
		video, err := transcript.ParseVideoURL(rawURL)
		if err != nil {
			c.JSON(http.StatusBadRequest, models.ErrorResponse{
				Error:   "invalid_url",
				Message: "Invalid video URL at index " + intToStr(i) + ": " + err.Error(),
				Code:    http.StatusBadRequest,
			})
			return
		}
		if video.Source == transcript.SourceOther {
			if err := transcript.ValidateExternalVideoURL(c.Request.Context(), video.URL); err != nil {
				c.JSON(http.StatusBadRequest, models.ErrorResponse{
					Error:   "invalid_url",
					Message: "Invalid video URL at index " + intToStr(i) + ": " + err.Error(),
					Code:    http.StatusBadRequest,
				})
				return
			}
		}
		parsed = append(parsed, parsedURL{fullURL: video.URL, videoID: video.VideoID})
	}

	// Step 2: Create the batch record
	batch := &models.Batch{
		Status:     models.StatusPending,
		TotalCount: len(parsed),
		UserID:     actor.UserID,
		APIKeyID:   actor.APIKeyID,
	}

	if err := h.DB.CreateBatch(c.Request.Context(), batch); err != nil {
		log.Printf("Failed to create batch: %v", err)
		c.JSON(http.StatusInternalServerError, models.ErrorResponse{
			Error:   "database_error",
			Message: "Failed to create batch record",
			Code:    http.StatusInternalServerError,
		})
		return
	}

	// Step 3: Create a transcript record for each URL, linked to the batch
	transcripts := make([]models.Transcript, 0, len(parsed))

	for _, p := range parsed {
		// Check for existing completed transcript for this video
		// If found, we create a new record pre-populated with the existing data
		// so it completes immediately without re-extraction.
		existing, _ := h.DB.GetTranscriptByYouTubeIDForActor(c.Request.Context(), p.videoID, actor.UserID, actor.APIKeyID)

		var t *models.Transcript
		var needsExtraction bool

		if existing != nil && existing.Status == models.StatusCompleted {
			// Reuse existing transcript data — skip re-extraction
			t = &models.Transcript{
				YouTubeURL:     p.fullURL,
				YouTubeID:      p.videoID,
				Status:         models.StatusCompleted,
				BatchID:        &batch.ID,
				Title:          existing.Title,
				ChannelName:    existing.ChannelName,
				Duration:       existing.Duration,
				Language:       existing.Language,
				TranscriptText: existing.TranscriptText,
				WordCount:      existing.WordCount,
				UserID:         actor.UserID,
				APIKeyID:       actor.APIKeyID,
			}
			needsExtraction = false
			log.Printf("Reusing existing transcript for %s (already extracted)", p.videoID)
		} else {
			// Create a pending transcript that needs extraction
			t = &models.Transcript{
				YouTubeURL: p.fullURL,
				YouTubeID:  p.videoID,
				Status:     models.StatusPending,
				BatchID:    &batch.ID,
				UserID:     actor.UserID,
				APIKeyID:   actor.APIKeyID,
			}
			needsExtraction = true
		}

		if err := h.DB.CreateTranscriptWithBatch(c.Request.Context(), t); err != nil {
			log.Printf("Failed to create transcript for %s: %v", p.videoID, err)
			// Continue with remaining URLs — partial success is better than total failure
			continue
		}

		// Only submit extraction job if this is a new transcript
		if needsExtraction {
			job := worker.Job{
				ID:        t.ID,
				Type:      worker.JobTranscriptExtraction,
				CreatedAt: time.Now(),
			}

			if err := h.Worker.Submit(job); err != nil {
				if h.isOwnerRequest(c) {
					ctx, cancel := context.WithTimeout(c.Request.Context(), 15*time.Second)
					blockingErr := h.Worker.SubmitBlocking(ctx, job)
					cancel()
					if blockingErr == nil {
						// queued successfully for owner; continue
						transcripts = append(transcripts, *t)
						continue
					}
				}
				log.Printf("Failed to queue extraction job for %s: %v", t.ID, err)
				t.Status = models.StatusFailed
				t.ErrorMessage = "Job queue is full, please try again later"
				_ = h.DB.UpdateTranscript(c.Request.Context(), t)
			}
		}

		transcripts = append(transcripts, *t)
	}

	if err := h.DB.UpdateBatchCounts(c.Request.Context(), batch.ID); err != nil {
		log.Printf("Failed to update batch counts for %s: %v", batch.ID, err)
	}

	// Return 202 Accepted with the batch and all transcript records
	c.JSON(http.StatusAccepted, models.BatchResponse{
		Batch:       *batch,
		Transcripts: transcripts,
	})
}

// GetBatch retrieves the status of a batch and its transcripts.
// GET /api/v1/batches/:id
//
// This endpoint recalculates the batch counts from the actual transcript
// statuses, ensuring accuracy even if a worker update was missed.
func (h *Handler) GetBatch(c *gin.Context) {
	id := c.Param("id")
	actor := getActorOwnership(c)

	batch, err := h.DB.GetBatchForActor(c.Request.Context(), id, actor.UserID, actor.APIKeyID)
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error:   "not_found",
			Message: "Batch not found",
			Code:    http.StatusNotFound,
		})
		return
	}

	// Recalculate the batch counts from actual transcript data after ownership
	// is confirmed so unauthorized reads never trigger writes.
	if err := h.DB.UpdateBatchCounts(c.Request.Context(), id); err != nil {
		log.Printf("Failed to update batch counts: %v", err)
		// Non-fatal — continue with potentially stale counts
	} else if refreshed, refreshErr := h.DB.GetBatchForActor(c.Request.Context(), id, actor.UserID, actor.APIKeyID); refreshErr == nil {
		batch = refreshed
	}

	transcripts, err := h.DB.GetTranscriptsByBatchForActor(c.Request.Context(), id, actor.UserID, actor.APIKeyID)
	if err != nil {
		log.Printf("Failed to get batch transcripts: %v", err)
		transcripts = []models.Transcript{} // Return empty array, not error
	}

	c.JSON(http.StatusOK, models.BatchStatusResponse{
		Batch:       *batch,
		Transcripts: transcripts,
	})
}

// intToStr is a tiny helper to convert an int to string for error messages.
// Go Pattern: We could use strconv.Itoa, but for simple cases like error
// messages, fmt.Sprintf is cleaner and more readable.
func intToStr(i int) string {
	return fmt.Sprintf("%d", i)
}
