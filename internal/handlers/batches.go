// batches.go handles batch transcript processing endpoints (MTA-8).
//
// Batch processing lets users submit multiple YouTube URLs at once.
// Each URL becomes its own transcript record, all linked to a single batch.
// The batch provides aggregate status tracking.
package handlers

import (
	"fmt"
	"log"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/transcript"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/worker"
)

// CreateBatch starts transcript extraction for multiple YouTube URLs.
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
			Message: "Provide 'urls' array with 1-10 YouTube URLs",
			Code:    http.StatusBadRequest,
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

	for i, url := range req.URLs {
		fullURL, videoID, err := transcript.ParseYouTubeURL(url)
		if err != nil {
			c.JSON(http.StatusBadRequest, models.ErrorResponse{
				Error:   "invalid_url",
				Message: "Invalid YouTube URL at index " + intToStr(i) + ": " + err.Error(),
				Code:    http.StatusBadRequest,
			})
			return
		}
		parsed = append(parsed, parsedURL{fullURL: fullURL, videoID: videoID})
	}

	// Step 2: Create the batch record
	batch := &models.Batch{
		Status:     models.StatusPending,
		TotalCount: len(parsed),
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
		existing, _ := h.DB.GetTranscriptByYouTubeID(c.Request.Context(), p.videoID)

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
				TranscriptText: existing.TranscriptText,
				WordCount:      existing.WordCount,
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
				log.Printf("Failed to queue extraction job for %s: %v", t.ID, err)
			}
		}

		transcripts = append(transcripts, *t)
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

	// First, update the batch counts from actual transcript data
	// Go Pattern: Self-healing data — we recalculate on every read
	// rather than trusting stale counters. The performance cost is
	// minimal since it's a single indexed query.
	if err := h.DB.UpdateBatchCounts(c.Request.Context(), id); err != nil {
		log.Printf("Failed to update batch counts: %v", err)
		// Non-fatal — continue with potentially stale counts
	}

	batch, err := h.DB.GetBatch(c.Request.Context(), id)
	if err != nil {
		c.JSON(http.StatusNotFound, models.ErrorResponse{
			Error:   "not_found",
			Message: "Batch not found",
			Code:    http.StatusNotFound,
		})
		return
	}

	transcripts, err := h.DB.GetTranscriptsByBatch(c.Request.Context(), id)
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
