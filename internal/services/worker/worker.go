// Package worker provides a background job processing system using goroutines.
//
// Go Pattern: Goroutines and channels are Go's concurrency primitives.
// A goroutine is like a lightweight thread (thousands are fine), and
// channels are typed pipes for communication between goroutines.
//
// This worker pool pattern is very common in Go:
// 1. Create a buffered channel as a job queue
// 2. Spawn N worker goroutines that read from the channel
// 3. Send jobs to the channel from your HTTP handlers
// 4. Workers process jobs concurrently
//
// Think of it like a restaurant: the channel is the order window,
// workers are the cooks, and handlers are the waiters taking orders.
package worker

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"sync"
	"time"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/audio"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/summary"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/transcript"
	webhookservice "github.com/Shimizu-Technology/media-tools-api/internal/services/webhook"
)

// JobType identifies what kind of work a job represents.
type JobType string

const (
	JobTranscriptExtraction  JobType = "transcript_extraction"
	JobSummaryGeneration     JobType = "summary_generation"
	JobAudioTranscription    JobType = "audio_transcription"
)

// Job represents a unit of work to be processed by a worker.
type Job struct {
	ID        string          // The database record ID
	Type      JobType
	Payload   json.RawMessage // Flexible payload — different job types need different data
	CreatedAt time.Time
}

// SummaryPayload is the data needed for a summary generation job.
type SummaryPayload struct {
	TranscriptID string `json:"transcript_id"`
	Model        string `json:"model"`
	Length       string `json:"length"`
	Style        string `json:"style"`
	SummaryID    string `json:"summary_id"`
}

// AudioPayload is the data needed for an audio transcription job.
// We store the temp file path instead of file bytes to avoid memory issues with large files.
type AudioPayload struct {
	AudioID      string `json:"audio_id"`
	TempFilePath string `json:"temp_file_path"`
	OriginalName string `json:"original_name"`
}

// Pool manages a pool of worker goroutines.
type Pool struct {
	jobs            chan Job
	workers         int
	db              *database.DB
	extractor       transcript.Extractor
	summarizer      *summary.Service
	audioTranscriber *audio.Transcriber // Audio transcription via Whisper
	webhooks        *webhookservice.Service // MTA-18: webhook notifications
	wg              sync.WaitGroup
	ctx             context.Context
	cancel          context.CancelFunc
}

// SetWebhookService sets the webhook service for notifications (MTA-18).
func (p *Pool) SetWebhookService(ws *webhookservice.Service) {
	p.webhooks = ws
}

// SetAudioTranscriber sets the audio transcriber for Whisper jobs.
func (p *Pool) SetAudioTranscriber(at *audio.Transcriber) {
	p.audioTranscriber = at
}

// notifyWebhook fires a webhook event if the service is configured.
func (p *Pool) notifyWebhook(event string, data interface{}) {
	if p.webhooks != nil {
		p.webhooks.NotifyEvent(p.ctx, event, data)
	}
}

// NewPool creates a new worker pool.
func NewPool(workers, queueSize int, db *database.DB, ext transcript.Extractor, sum *summary.Service) *Pool {
	ctx, cancel := context.WithCancel(context.Background())
	return &Pool{
		jobs:       make(chan Job, queueSize), // Buffered channel
		workers:    workers,
		db:         db,
		extractor:  ext,
		summarizer: sum,
		ctx:        ctx,
		cancel:     cancel,
	}
}

// Start launches the worker goroutines.
// Go Pattern: The `go` keyword starts a new goroutine (lightweight thread).
// Each worker runs in its own goroutine, reading from the shared jobs channel.
func (p *Pool) Start() {
	log.Printf("🚀 Starting %d background workers", p.workers)
	for i := 0; i < p.workers; i++ {
		p.wg.Add(1)
		go p.worker(i) // Launch worker goroutine
	}
}

// Stop gracefully shuts down all workers.
// Go Pattern: Close the channel + cancel the context + wait for completion.
func (p *Pool) Stop() {
	log.Println("⏹️  Stopping workers...")
	p.cancel()     // Signal all workers to stop
	close(p.jobs)  // Close the channel (workers will drain remaining jobs)
	p.wg.Wait()    // Wait for all workers to finish
	log.Println("✅ All workers stopped")
}

// Submit adds a job to the queue.
// Returns an error if the queue is full (non-blocking).
func (p *Pool) Submit(job Job) error {
	// Go Pattern: `select` with `default` makes channel operations non-blocking.
	// Without default, sending to a full channel would block the HTTP handler.
	select {
	case p.jobs <- job:
		log.Printf("📥 Job queued: %s (type: %s)", job.ID, job.Type)
		return nil
	default:
		return fmt.Errorf("job queue is full; try again later")
	}
}

// QueueSize returns the current number of jobs in the queue.
func (p *Pool) QueueSize() int {
	return len(p.jobs)
}

// WorkerCount returns the number of workers.
func (p *Pool) WorkerCount() int {
	return p.workers
}

// worker is the main loop for each worker goroutine.
// It reads jobs from the channel and processes them.
func (p *Pool) worker(id int) {
	defer p.wg.Done() // Signal completion when this worker exits

	log.Printf("👷 Worker %d started", id)

	// Go Pattern: `range` over a channel reads values until the channel is closed.
	// This is the idiomatic way to consume from a channel.
	for job := range p.jobs {
		// Check if we should stop
		select {
		case <-p.ctx.Done():
			log.Printf("👷 Worker %d shutting down", id)
			return
		default:
			// Continue processing
		}

		log.Printf("👷 Worker %d processing job: %s (type: %s)", id, job.ID, job.Type)

		// Go Pattern: Error handling — each job type has its own handler.
		// We use a switch statement (like a match/case in other languages).
		var err error
		switch job.Type {
		case JobTranscriptExtraction:
			err = p.processTranscript(job)
		case JobSummaryGeneration:
			err = p.processSummary(job)
		case JobAudioTranscription:
			err = p.processAudioTranscription(job)
		default:
			log.Printf("❌ Worker %d: unknown job type: %s", id, job.Type)
		}

		if err != nil {
			log.Printf("❌ Worker %d: job %s failed: %v", id, job.ID, err)
		} else {
			log.Printf("✅ Worker %d: job %s completed", id, job.ID)
		}
	}

	log.Printf("👷 Worker %d stopped", id)
}

// processTranscript handles transcript extraction jobs.
func (p *Pool) processTranscript(job Job) error {
	ctx := p.ctx

	// Get the transcript record from the database
	t, err := p.db.GetTranscript(ctx, job.ID)
	if err != nil {
		return fmt.Errorf("failed to get transcript: %w", err)
	}

	// Update status to processing
	t.Status = models.StatusProcessing
	if err := p.db.UpdateTranscript(ctx, t); err != nil {
		return fmt.Errorf("failed to update status: %w", err)
	}

	// Extract the transcript
	result, err := p.extractor.Extract(ctx, t.YouTubeID)
	if err != nil {
		t.Status = models.StatusFailed
		t.ErrorMessage = err.Error()
		p.db.UpdateTranscript(ctx, t)
		p.notifyWebhook("transcript.failed", t) // MTA-18
		if t.BatchID != nil {
			p.db.UpdateBatchCounts(ctx, *t.BatchID)
		}
		return fmt.Errorf("extraction failed: %w", err)
	}

	t.Title = result.Title
	t.ChannelName = result.ChannelName
	t.Duration = result.Duration
	t.Language = result.Language
	t.TranscriptText = result.Transcript
	t.WordCount = result.WordCount
	t.Status = models.StatusCompleted

	if err := p.db.UpdateTranscript(ctx, t); err != nil {
		return fmt.Errorf("failed to save transcript: %w", err)
	}

	p.notifyWebhook("transcript.completed", t) // MTA-18

	if t.BatchID != nil {
		if err := p.db.UpdateBatchCounts(ctx, *t.BatchID); err != nil {
			log.Printf("⚠️  Failed to update batch counts for %s: %v", *t.BatchID, err)
		}
		// Check if batch completed
		batch, batchErr := p.db.GetBatch(ctx, *t.BatchID)
		if batchErr == nil && batch.Status == models.StatusCompleted {
			p.notifyWebhook("batch.completed", batch)
		}
	}

	return nil
}

// processSummary handles AI summary generation jobs.
func (p *Pool) processSummary(job Job) error {
	ctx := p.ctx

	// Parse the job payload
	var payload SummaryPayload
	if err := json.Unmarshal(job.Payload, &payload); err != nil {
		return fmt.Errorf("invalid summary payload: %w", err)
	}

	// Get the transcript text
	t, err := p.db.GetTranscript(ctx, payload.TranscriptID)
	if err != nil {
		return fmt.Errorf("transcript not found: %w", err)
	}

	if t.Status != models.StatusCompleted {
		return fmt.Errorf("transcript not ready (status: %s)", t.Status)
	}

	// Generate the summary
	opts := summary.Options{
		Model:  payload.Model,
		Length: payload.Length,
		Style:  payload.Style,
	}

	result, err := p.summarizer.Summarize(ctx, t.TranscriptText, opts)
	if err != nil {
		return fmt.Errorf("summary generation failed: %w", err)
	}

	// Save to database
	keyPointsJSON, _ := json.Marshal(result.KeyPoints)

	s := &models.Summary{
		ID:           payload.SummaryID,
		TranscriptID: payload.TranscriptID,
		ModelUsed:    result.Model,
		PromptUsed:   result.Prompt,
		SummaryText:  result.Summary,
		KeyPoints:    keyPointsJSON,
		Length:       payload.Length,
		Style:        payload.Style,
	}

	// If we have a pre-created summary ID, update it; otherwise create new
	if payload.SummaryID != "" {
		// Update existing placeholder
		return p.db.CreateSummary(ctx, s)
	}

	return p.db.CreateSummary(ctx, s)
}

// processAudioTranscription handles audio transcription jobs via Whisper API.
func (p *Pool) processAudioTranscription(job Job) error {
	ctx := p.ctx

	// Parse the job payload
	var payload AudioPayload
	if err := json.Unmarshal(job.Payload, &payload); err != nil {
		return fmt.Errorf("invalid audio payload: %w", err)
	}

	// Get the audio transcription record from the database
	at, err := p.db.GetAudioTranscription(ctx, payload.AudioID)
	if err != nil {
		return fmt.Errorf("failed to get audio transcription: %w", err)
	}

	// Update status to processing
	at.Status = "processing"
	if err := p.db.UpdateAudioTranscription(ctx, at); err != nil {
		log.Printf("⚠️  Failed to update audio status to processing: %v", err)
	}

	// Open the temp file
	file, err := os.Open(payload.TempFilePath)
	if err != nil {
		at.Status = "failed"
		at.ErrorMessage = "Failed to read uploaded file: " + err.Error()
		p.db.UpdateAudioTranscription(ctx, at)
		return fmt.Errorf("failed to open temp file: %w", err)
	}
	defer func() {
		file.Close()
		// Clean up temp file after processing
		os.Remove(payload.TempFilePath)
	}()

	// Check if transcriber is configured
	if p.audioTranscriber == nil || !p.audioTranscriber.IsConfigured() {
		at.Status = "failed"
		at.ErrorMessage = "Audio transcription is not configured. Set OPENAI_API_KEY."
		p.db.UpdateAudioTranscription(ctx, at)
		return fmt.Errorf("audio transcriber not configured")
	}

	// Call the Whisper API
	result, err := p.audioTranscriber.Transcribe(ctx, file, payload.OriginalName)
	if err != nil {
		log.Printf("❌ Whisper transcription failed for %s: %v", payload.OriginalName, err)
		at.Status = "failed"
		at.ErrorMessage = err.Error()
		p.db.UpdateAudioTranscription(ctx, at)
		p.notifyWebhook("audio.failed", at)
		return fmt.Errorf("transcription failed: %w", err)
	}

	// Update the record with results
	at.TranscriptText = result.Text
	at.Language = result.Language
	at.Duration = result.Duration
	at.WordCount = audio.CountWords(result.Text)
	at.Status = "completed"

	if err := p.db.UpdateAudioTranscription(ctx, at); err != nil {
		log.Printf("⚠️  Failed to save audio transcription result: %v", err)
		return fmt.Errorf("failed to save transcription: %w", err)
	}

	p.notifyWebhook("audio.completed", at)
	log.Printf("✅ Audio transcription completed: %s (%s, %.0fs, %d words)",
		payload.OriginalName, result.Language, result.Duration, at.WordCount)

	return nil
}
