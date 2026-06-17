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
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/audio"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/storage"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/summary"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/transcript"
	webhookservice "github.com/Shimizu-Technology/media-tools-api/internal/services/webhook"
)

// JobType identifies what kind of work a job represents.
type JobType string

const (
	JobTranscriptExtraction JobType = "transcript_extraction"
	JobSummaryGeneration    JobType = "summary_generation"
	JobAudioTranscription   JobType = "audio_transcription"
)

const whisperTargetBytes = 24 << 20 // Keep below 25MB hard limit to account for multipart overhead
const whisperInitialSegmentSeconds = 300
const whisperFFmpegTimeout = 30 * time.Minute
const whisperProbeTimeout = 30 * time.Second

const repeatedSegmentRunMin = 8
const repeatedSegmentLongRunMin = 16
const repeatedSegmentPhraseWordLimit = 8

// Normalize tricky browser/video uploads to MP3 for Whisper. Playable browser
// MediaRecorder M4A/WebM files can still decode poorly in Whisper and trigger
// hallucinated transcripts. MP3 is less compact, but it is the most consistently
// accepted container/codec combination for speech uploads.
const whisperPreparedExtension = ".mp3"
const whisperPreparedBitrate = "64k"

func requiresWhisperTranscode(path string) bool {
	switch strings.ToLower(filepath.Ext(path)) {
	// We accept these uploads at the API boundary, but normalize them before
	// transcription so the worker feeds Whisper a predictable audio format.
	case ".mp4", ".m4a", ".webm", ".flac", ".ogg":
		return true
	default:
		return false
	}
}

// Job represents a unit of work to be processed by a worker.
type Job struct {
	ID        string // The database record ID
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
	ContentType  string `json:"content_type"`
	SummaryID    string `json:"summary_id"`
}

// AudioPayload is the data needed for an audio transcription job.
// We store the temp file path instead of file bytes to avoid memory issues with large files.
type AudioPayload struct {
	AudioID      string `json:"audio_id"`
	TempFilePath string `json:"temp_file_path"`
	AudioS3Key   string `json:"audio_s3_key,omitempty"`
	OriginalName string `json:"original_name"`
}

// Pool manages a pool of worker goroutines.
type Pool struct {
	jobs             chan Job
	workers          int
	db               *database.DB
	extractor        transcript.Extractor
	summarizer       *summary.Service
	audioTranscriber *audio.Transcriber // Audio transcription via Whisper
	audioStorage     *storage.S3
	webhooks         *webhookservice.Service // MTA-18: webhook notifications
	webhookSem       chan struct{}           // Caps concurrent webhook goroutines
	wg               sync.WaitGroup
	ctx              context.Context
	cancel           context.CancelFunc
	stopOnce         sync.Once
}

// SetWebhookService sets the webhook service for notifications (MTA-18).
func (p *Pool) SetWebhookService(ws *webhookservice.Service) {
	p.webhooks = ws
}

// SetAudioTranscriber sets the audio transcriber for Whisper jobs.
func (p *Pool) SetAudioTranscriber(at *audio.Transcriber) {
	p.audioTranscriber = at
}

func (p *Pool) SetAudioStorage(as *storage.S3) {
	p.audioStorage = as
}

// notifyWebhook fires a webhook event asynchronously if the service is configured.
// BUG FIX: Previously synchronous — slow webhook delivery would block workers.
// Now fires in a goroutine with its own timeout context.
func (p *Pool) notifyWebhook(event string, apiKeyID *string, data interface{}) {
	if apiKeyID == nil || *apiKeyID == "" {
		return
	}
	if p.webhooks != nil {
		// Acquire semaphore slot (non-blocking: drop webhook if at capacity)
		select {
		case p.webhookSem <- struct{}{}:
			go func() {
				defer func() { <-p.webhookSem }()
				ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
				defer cancel()
				p.webhooks.NotifyEvent(ctx, event, *apiKeyID, data)
			}()
		default:
			log.Printf("⚠️ Webhook semaphore full, dropping %s event", event)
		}
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
		webhookSem: make(chan struct{}, 20), // Cap concurrent webhook goroutines
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
	p.stopOnce.Do(func() {
		log.Println("⏹️  Stopping workers...")
		close(p.jobs) // Closing the queue lets workers drain already-queued jobs.

		done := make(chan struct{})
		go func() {
			p.wg.Wait()
			close(done)
		}()

		select {
		case <-done:
			log.Println("✅ All workers stopped")
		case <-time.After(30 * time.Second):
			log.Println("⚠️  Worker drain timed out, canceling active jobs")
			p.cancel()
			<-done
			log.Println("✅ All workers stopped after forced cancellation")
		}
	})
}

// Submit adds a job to the queue.
// Returns an error if the queue is full (non-blocking).
func (p *Pool) Submit(job Job) (err error) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("⚠️  Rejected job %s while worker pool was stopping", job.ID)
			err = fmt.Errorf("worker pool is stopping")
		}
	}()

	// Go Pattern: `select` with `default` makes channel operations non-blocking.
	// Without default, sending to a full channel would block the HTTP handler.
	select {
	case <-p.ctx.Done():
		return fmt.Errorf("worker pool is stopping")
	case p.jobs <- job:
		log.Printf("📥 Job queued: %s (type: %s)", job.ID, job.Type)
		return nil
	default:
		return fmt.Errorf("job queue is full; try again later")
	}
}

// SubmitBlocking adds a job to the queue and blocks until it can be queued
// or the provided context is canceled.
func (p *Pool) SubmitBlocking(ctx context.Context, job Job) (err error) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("⚠️  Rejected blocking job %s while worker pool was stopping", job.ID)
			err = fmt.Errorf("worker pool is stopping")
		}
	}()

	select {
	case <-p.ctx.Done():
		return fmt.Errorf("worker pool is stopping")
	case p.jobs <- job:
		log.Printf("📥 Job queued (blocking): %s (type: %s)", job.ID, job.Type)
		return nil
	case <-ctx.Done():
		return ctx.Err()
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

// RecoverTranscriptJobs requeues pending/processing transcript jobs on startup.
func (p *Pool) RecoverTranscriptJobs(ctx context.Context, limit int) (int, error) {
	rows, err := p.db.ListRecoverableTranscripts(ctx, limit)
	if err != nil {
		return 0, err
	}

	requeued := 0
	var recoveryErrs []string
	for _, t := range rows {
		if t.Status == models.StatusCompleted || t.Status == models.StatusFailed {
			continue
		}
		if t.Status == models.StatusProcessing {
			// A worker died mid-job, so reflect reality before requeueing it.
			t.Status = models.StatusPending
			if err := p.db.UpdateTranscript(ctx, &t); err != nil {
				recoveryErrs = append(recoveryErrs, fmt.Sprintf("reset %s: %v", t.ID, err))
				log.Printf("⚠️  Failed to reset transcript %s for recovery: %v", t.ID, err)
				continue
			}
		}

		job := Job{
			ID:        t.ID,
			Type:      JobTranscriptExtraction,
			CreatedAt: time.Now(),
		}
		if err := p.Submit(job); err == nil {
			requeued++
		} else {
			recoveryErrs = append(recoveryErrs, fmt.Sprintf("requeue %s: %v", t.ID, err))
			log.Printf("⚠️  Failed to requeue transcript %s during recovery: %v", t.ID, err)
		}
	}

	if len(recoveryErrs) > 0 {
		return requeued, fmt.Errorf("transcript recovery completed with %d issue(s): %s", len(recoveryErrs), strings.Join(recoveryErrs, "; "))
	}

	return requeued, nil
}

// RecoverAudioJobs requeues pending/processing audio jobs on startup.
func (p *Pool) RecoverAudioJobs(ctx context.Context, limit int) (int, error) {
	rows, err := p.db.ListRecoverableAudioTranscriptions(ctx, limit)
	if err != nil {
		return 0, err
	}

	requeued := 0
	var recoveryErrs []string
	for _, at := range rows {
		if at.Status == "completed" {
			continue
		}

		if at.Status == "processing" {
			// A worker died mid-job, so reflect reality before requeueing it.
			at.Status = "pending"
			at.ProcessingStage = "queued"
			at.ProcessingProgress = 0
			if err := p.db.UpdateAudioTranscription(ctx, &at); err != nil {
				recoveryErrs = append(recoveryErrs, fmt.Sprintf("reset %s: %v", at.ID, err))
				log.Printf("⚠️  Failed to reset audio transcription %s for recovery: %v", at.ID, err)
				continue
			}
		}

		payload := AudioPayload{
			AudioID:      at.ID,
			AudioS3Key:   at.AudioS3Key,
			OriginalName: at.OriginalName,
		}
		payloadJSON, err := json.Marshal(payload)
		if err != nil {
			recoveryErrs = append(recoveryErrs, fmt.Sprintf("marshal %s: %v", at.ID, err))
			log.Printf("⚠️  Failed to marshal audio job %s during recovery: %v", at.ID, err)
			continue
		}

		job := Job{
			ID:        at.ID,
			Type:      JobAudioTranscription,
			Payload:   payloadJSON,
			CreatedAt: time.Now(),
		}
		if err := p.Submit(job); err != nil {
			recoveryErrs = append(recoveryErrs, fmt.Sprintf("requeue %s: %v", at.ID, err))
			log.Printf("⚠️  Failed to requeue audio transcription %s during recovery: %v", at.ID, err)
			continue
		}

		requeued++
		if err := p.db.UpdateAudioProcessing(ctx, at.ID, "queued", 0); err != nil {
			recoveryErrs = append(recoveryErrs, fmt.Sprintf("mark queued %s: %v", at.ID, err))
			log.Printf("⚠️  Failed to update recovered audio transcription %s to queued: %v", at.ID, err)
		}
	}

	if len(recoveryErrs) > 0 {
		return requeued, fmt.Errorf("audio recovery completed with %d issue(s): %s", len(recoveryErrs), strings.Join(recoveryErrs, "; "))
	}

	return requeued, nil
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

	// Extract the transcript (supports YouTube, Vimeo, and other yt-dlp sites)
	result, err := p.extractor.ExtractFromURL(ctx, t.YouTubeURL, t.YouTubeID)
	if err != nil {
		t.Status = models.StatusFailed
		t.ErrorMessage = err.Error()
		p.db.UpdateTranscript(ctx, t)
		p.notifyWebhook("transcript.failed", t.APIKeyID, t) // MTA-18
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

	p.notifyWebhook("transcript.completed", t.APIKeyID, t) // MTA-18

	if t.BatchID != nil {
		if err := p.db.UpdateBatchCounts(ctx, *t.BatchID); err != nil {
			log.Printf("⚠️  Failed to update batch counts for %s: %v", *t.BatchID, err)
		}
		// Check if batch completed
		batch, batchErr := p.db.GetBatch(ctx, *t.BatchID)
		if batchErr == nil && batch.Status == models.StatusCompleted {
			p.notifyWebhook("batch.completed", batch.APIKeyID, batch)
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
		Model:       payload.Model,
		Length:      payload.Length,
		Style:       payload.Style,
		ContentType: payload.ContentType,
	}

	result, err := p.summarizer.Summarize(ctx, t.TranscriptText, opts)
	if err != nil {
		// BUG FIX: Notify via webhook so users know the summary failed
		// (Summary model has no status field, so failure was previously silent)
		p.notifyWebhook("summary.failed", t.APIKeyID, map[string]interface{}{
			"transcript_id": payload.TranscriptID,
			"summary_id":    payload.SummaryID,
			"error":         err.Error(),
		})
		log.Printf("❌ Summary generation failed for transcript %s: %v", payload.TranscriptID, err)
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
		if err := p.db.CreateSummary(ctx, s); err != nil {
			return err
		}
	} else {
		if err := p.db.CreateSummary(ctx, s); err != nil {
			return err
		}
	}

	p.notifyWebhook("summary.completed", t.APIKeyID, s)
	return nil
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

	if retryCount, err := p.db.IncrementAudioRetryCount(ctx, at.ID); err == nil {
		at.RetryCount = retryCount
	}
	log.Printf("🎙️  Audio job %s started: %s (retry=%d, s3=%t)", at.ID, payload.OriginalName, at.RetryCount, payload.AudioS3Key != "")

	// Update status to processing
	at.Status = "processing"
	at.ProcessingStage = "starting"
	at.ProcessingProgress = 5
	if err := p.db.UpdateAudioTranscription(ctx, at); err != nil {
		log.Printf("⚠️  Failed to update audio status to processing: %v", err)
	}

	if payload.TempFilePath == "" {
		if payload.AudioS3Key == "" {
			payload.AudioS3Key = at.AudioS3Key
		}
		if p.audioStorage == nil || !p.audioStorage.IsConfigured() || payload.AudioS3Key == "" {
			at.Status = "failed"
			at.ErrorMessage = "Audio source file is unavailable for processing."
			at.ProcessingStage = "failed"
			at.ProcessingProgress = 100
			_ = p.db.UpdateAudioTranscription(ctx, at)
			return fmt.Errorf("no local temp file or durable S3 key available")
		}
		_ = p.db.UpdateAudioProcessing(ctx, at.ID, "downloading", 10)
		log.Printf("⬇️  Audio job %s downloading source from storage key %s", at.ID, payload.AudioS3Key)
		ext := filepath.Ext(at.Filename)
		if ext == "" {
			ext = ".webm"
		}
		payload.TempFilePath = filepath.Join(os.TempDir(), fmt.Sprintf("%s%s", at.ID, ext))
		if err := p.audioStorage.DownloadFile(ctx, payload.AudioS3Key, payload.TempFilePath); err != nil {
			at.Status = "failed"
			at.ErrorMessage = "Failed to download source audio: " + err.Error()
			at.ProcessingStage = "failed"
			at.ProcessingProgress = 100
			_ = p.db.UpdateAudioTranscription(ctx, at)
			return fmt.Errorf("failed to download source audio: %w", err)
		}
		log.Printf("✅ Audio job %s downloaded source to %s", at.ID, payload.TempFilePath)
	} else {
		log.Printf("📁 Audio job %s using local upload file %s", at.ID, payload.TempFilePath)
	}

	// Ensure temp file is always cleaned up
	defer os.Remove(payload.TempFilePath)

	// Check if transcriber is configured
	if p.audioTranscriber == nil || !p.audioTranscriber.IsConfigured() {
		at.Status = "failed"
		at.ErrorMessage = "Audio transcription is not configured. Set OPENAI_API_KEY."
		p.db.UpdateAudioTranscription(ctx, at)
		return fmt.Errorf("audio transcriber not configured")
	}

	transcriptionPath := payload.TempFilePath
	var cleanupPaths []string
	defer func() {
		for _, p := range cleanupPaths {
			_ = os.Remove(p)
		}
	}()

	fileInfo, err := os.Stat(payload.TempFilePath)
	if err != nil {
		at.Status = "failed"
		at.ErrorMessage = "Failed to read uploaded file info: " + err.Error()
		p.db.UpdateAudioTranscription(ctx, at)
		return fmt.Errorf("failed to stat temp file: %w", err)
	}
	log.Printf("📊 Audio job %s source ready: %s (%.1fMB)", at.ID, filepath.Ext(payload.TempFilePath), bytesToMB(fileInfo.Size()))

	var transcriptionParts []string
	if fileInfo.Size() > whisperTargetBytes || requiresWhisperTranscode(payload.TempFilePath) {
		_ = p.db.UpdateAudioProcessing(ctx, at.ID, "transcoding", 25)
		compressedPath := payload.TempFilePath + ".whisper" + whisperPreparedExtension
		log.Printf("🎚️  Audio job %s preparing recording for Whisper: %s (%.1fMB)", at.ID, payload.OriginalName, bytesToMB(fileInfo.Size()))
		lastLoggedTranscodeProgress := 25
		transcodeProgress := func(progress int) {
			_ = p.db.UpdateAudioProcessing(ctx, at.ID, "transcoding", progress)
			if progress >= lastLoggedTranscodeProgress+3 || progress >= 34 {
				lastLoggedTranscodeProgress = progress
				log.Printf("🎚️  Audio job %s transcode progress: %d%%", at.ID, progress)
			}
		}
		if err := transcodeForWhisper(ctx, payload.TempFilePath, compressedPath, transcodeProgress); err != nil {
			at.Status = "failed"
			at.ErrorMessage = "Failed to compress audio for transcription: " + err.Error()
			p.db.UpdateAudioTranscription(ctx, at)
			return fmt.Errorf("failed to transcode large audio: %w", err)
		}
		cleanupPaths = append(cleanupPaths, compressedPath)

		compressedInfo, err := os.Stat(compressedPath)
		if err != nil {
			at.Status = "failed"
			at.ErrorMessage = "Failed to prepare compressed audio: " + err.Error()
			p.db.UpdateAudioTranscription(ctx, at)
			return fmt.Errorf("failed to stat compressed audio: %w", err)
		}

		log.Printf("🎚️  Transcoded recording for Whisper: %s %.1fMB -> %.1fMB",
			payload.OriginalName,
			bytesToMB(fileInfo.Size()),
			bytesToMB(compressedInfo.Size()),
		)

		if compressedInfo.Size() > whisperTargetBytes {
			segmentSeconds := whisperInitialSegmentSeconds
			for {
				_ = p.db.UpdateAudioProcessing(ctx, at.ID, "chunking", 35)
				log.Printf("🧩 Audio job %s splitting compressed audio into %ds segments", at.ID, segmentSeconds)
				segmentPaths, err := splitAudioForWhisper(ctx, compressedPath, segmentSeconds)
				if err != nil {
					at.Status = "failed"
					at.ErrorMessage = "Failed to split long audio for transcription: " + err.Error()
					p.db.UpdateAudioTranscription(ctx, at)
					return fmt.Errorf("failed to split compressed audio: %w", err)
				}
				cleanupPaths = append(cleanupPaths, segmentPaths...)

				oversized := false
				largestSegmentBytes := int64(0)
				for _, segmentPath := range segmentPaths {
					info, err := os.Stat(segmentPath)
					if err != nil {
						at.Status = "failed"
						at.ErrorMessage = "Failed to inspect audio segment: " + err.Error()
						p.db.UpdateAudioTranscription(ctx, at)
						return fmt.Errorf("failed to stat segment %s: %w", segmentPath, err)
					}
					if info.Size() > whisperTargetBytes {
						oversized = true
					}
					if info.Size() > largestSegmentBytes {
						largestSegmentBytes = info.Size()
					}
				}

				if !oversized {
					transcriptionParts = segmentPaths
					log.Printf("🧩 Audio job %s split into %d segment(s) at %ds each for Whisper (largest %.1fMB)", at.ID, len(segmentPaths), segmentSeconds, bytesToMB(largestSegmentBytes))
					break
				}

				log.Printf("🧩 Audio job %s segments still too large at %ds (largest %.1fMB); retrying smaller segments", at.ID, segmentSeconds, bytesToMB(largestSegmentBytes))
				segmentSeconds /= 2
				if segmentSeconds < 120 {
					at.Status = "failed"
					at.ErrorMessage = "Audio is too large to process safely even after chunking."
					p.db.UpdateAudioTranscription(ctx, at)
					return fmt.Errorf("chunked segments still exceed whisper size limits")
				}
			}
		} else {
			transcriptionPath = compressedPath
		}
	} else {
		log.Printf("🎙️  Audio job %s source can be sent directly to Whisper without transcoding", at.ID)
	}

	var transcriptText string
	var language string
	var duration float64
	var transcriptionSegments []audio.TranscriptionSegment

	if len(transcriptionParts) == 0 {
		_ = p.db.UpdateAudioProcessing(ctx, at.ID, "transcribing", 70)
		log.Printf("📝 Audio job %s sending single file to Whisper: %s", at.ID, filepath.Base(transcriptionPath))
		// Single-file transcription
		result, err := p.transcribeFile(ctx, transcriptionPath, payload.OriginalName)
		if err != nil {
			log.Printf("❌ Whisper transcription failed for %s: %v", payload.OriginalName, err)
			at.Status = "failed"
			at.ErrorMessage = err.Error()
			p.db.UpdateAudioTranscription(ctx, at)
			p.notifyWebhook("audio.failed", at.APIKeyID, at)
			return fmt.Errorf("transcription failed: %w", err)
		}
		cleanedText, cleanedSegments, removedSegments := sanitizeTranscriptionResult(result)
		if removedSegments > 0 {
			log.Printf("🧹 Audio job %s removed %d repeated Whisper segment(s) from transcription output", at.ID, removedSegments)
		}
		transcriptText = cleanedText
		language = result.Language
		duration = result.Duration
		transcriptionSegments = append(transcriptionSegments, cleanedSegments...)
	} else {
		partTexts := make([]string, 0, len(transcriptionParts))
		languageCounts := map[string]int{}
		for idx, partPath := range transcriptionParts {
			if len(transcriptionParts) > 0 {
				progress := 40 + int(float64(idx)/float64(len(transcriptionParts))*50)
				_ = p.db.UpdateAudioProcessing(ctx, at.ID, "transcribing", progress)
			}
			partName := fmt.Sprintf("%s.part.%03d%s",
				strings.TrimSuffix(payload.OriginalName, filepath.Ext(payload.OriginalName)),
				idx+1,
				filepath.Ext(partPath),
			)
			log.Printf("📝 Audio job %s sending chunk %d/%d to Whisper", at.ID, idx+1, len(transcriptionParts))
			result, err := p.transcribeFile(ctx, partPath, partName)
			if err != nil {
				log.Printf("❌ Whisper chunk transcription failed (%s): %v", partName, err)
				at.Status = "failed"
				at.ErrorMessage = err.Error()
				p.db.UpdateAudioTranscription(ctx, at)
				p.notifyWebhook("audio.failed", at.APIKeyID, at)
				return fmt.Errorf("chunk transcription failed (%s): %w", partName, err)
			}
			cleanedText, cleanedSegments, removedSegments := sanitizeTranscriptionResult(result)
			if removedSegments > 0 {
				log.Printf("🧹 Audio job %s removed %d repeated Whisper segment(s) from chunk %d/%d", at.ID, removedSegments, idx+1, len(transcriptionParts))
			}
			partTexts = append(partTexts, cleanedText)
			duration += result.Duration
			transcriptionSegments = append(transcriptionSegments, cleanedSegments...)
			if result.Language != "" {
				languageCounts[result.Language]++
			}
		}
		transcriptText = strings.TrimSpace(strings.Join(partTexts, "\n\n"))
		language = pickDominantLanguage(languageCounts)
	}

	// Update the record with results
	_ = p.db.UpdateAudioProcessing(ctx, at.ID, "stitching", 95)
	log.Printf("🧵 Audio job %s stitching transcription result", at.ID)
	latest, err := p.db.GetAudioTranscription(ctx, at.ID)
	if err == nil && latest.Status == "failed" {
		return fmt.Errorf("audio transcription stopped before completion")
	}
	stitchedText, stitchedSegments, stitchedRemovedSegments := sanitizeStitchedTranscription(transcriptText, transcriptionSegments)
	if stitchedRemovedSegments > 0 {
		log.Printf("🧹 Audio job %s removed %d repeated Whisper segment(s) after stitching", at.ID, stitchedRemovedSegments)
	}
	transcriptText = stitchedText
	transcriptionSegments = stitchedSegments

	at.TranscriptText = transcriptText
	at.Language = language
	at.Duration = duration
	at.WordCount = audio.CountWords(transcriptText)

	// Treat empty transcripts as a processing failure so users can retry immediately
	// instead of seeing a misleading "completed" state that cannot be chatted with.
	if strings.TrimSpace(at.TranscriptText) == "" || at.WordCount == 0 {
		at.Status = "failed"
		at.ErrorMessage = "No speech was detected in this audio. Please re-record or upload a clearer recording and try again."
		at.ProcessingStage = "failed"
		at.ProcessingProgress = 100
		updated, err := p.db.UpdateAudioTranscriptionIfActive(ctx, at)
		if err != nil {
			return fmt.Errorf("failed to save empty-transcript failure status: %w", err)
		}
		if !updated {
			return fmt.Errorf("audio transcription stopped before completion")
		}
		p.notifyWebhook("audio.failed", at.APIKeyID, at)
		return fmt.Errorf("empty transcription result for %s", payload.OriginalName)
	}

	if qualityErr := validateTranscriptionQuality(at.TranscriptText, at.Duration, transcriptionSegments); qualityErr != nil {
		// Do not persist known-bad hallucinated text. Failed records are still
		// retriable from saved audio, and keeping transcript_text empty prevents
		// accidental export/API/UI exposure of junk output.
		at.TranscriptText = ""
		at.WordCount = 0
		at.Status = "failed"
		at.ErrorMessage = "Transcription quality check failed: " + qualityErr.Error() + ". The original recording was saved, so you can re-transcribe it from the same audio."
		at.ProcessingStage = "failed"
		at.ProcessingProgress = 100
		updated, err := p.db.UpdateAudioTranscriptionIfActive(ctx, at)
		if err != nil {
			return fmt.Errorf("failed to save low-quality transcription failure status: %w", err)
		}
		if !updated {
			return fmt.Errorf("audio transcription stopped before completion")
		}
		p.notifyWebhook("audio.failed", at.APIKeyID, at)
		return fmt.Errorf("transcription quality check failed for %s: %w", payload.OriginalName, qualityErr)
	}

	at.Status = "completed"
	at.ProcessingStage = "completed"
	at.ProcessingProgress = 100

	updated, err := p.db.UpdateAudioTranscriptionIfActive(ctx, at)
	if err != nil {
		log.Printf("⚠️  Failed to save audio transcription result: %v", err)
		return fmt.Errorf("failed to save transcription: %w", err)
	}
	if !updated {
		return fmt.Errorf("audio transcription stopped before completion")
	}

	p.notifyWebhook("audio.completed", at.APIKeyID, at)
	log.Printf("✅ Audio transcription completed: %s (%s, %.0fs, %d words)",
		payload.OriginalName, language, duration, at.WordCount)

	return nil
}

func (p *Pool) transcribeFile(ctx context.Context, path, originalName string) (*audio.TranscriptionResult, error) {
	return p.transcribeFileWithRetry(ctx, path, originalName, 4)
}

// whisperUploadFilename ensures the multipart filename extension matches the
// actual file being uploaded. OpenAI validates the uploaded media container; if
// we transcode a WhatsApp .mp4 to MP3 but still send the original .mp4 filename,
// Whisper can reject it as an invalid format.
func whisperUploadFilename(path, originalName string) string {
	actualExt := strings.ToLower(filepath.Ext(path))
	if actualExt == "" {
		return filepath.Base(originalName)
	}
	base := strings.TrimSuffix(filepath.Base(originalName), filepath.Ext(originalName))
	if strings.TrimSpace(base) == "" {
		base = strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
	}
	return base + actualExt
}

// isRetryableError checks if a Whisper API error is transient and worth retrying.
// Retryable: 5xx server errors, 429 rate limits, timeouts, network errors.
// Non-retryable: 4xx client errors (bad format, bad API key, etc).
func isRetryableError(err error) bool {
	if err == nil {
		return false
	}

	// Check for structured WhisperAPIError first (preferred — no string parsing)
	var whisperErr *audio.WhisperAPIError
	if errors.As(err, &whisperErr) {
		if whisperErr.StatusCode == 429 {
			return true // Rate limited
		}
		if whisperErr.StatusCode >= 500 {
			return true // Server error
		}
		if whisperErr.StatusCode >= 400 {
			return false // Client error (bad request, unauthorized, etc)
		}
	}

	// Network/timeout errors are always retryable
	errStr := err.Error()
	if strings.Contains(errStr, "timeout") || strings.Contains(errStr, "connection") ||
		strings.Contains(errStr, "EOF") || strings.Contains(errStr, "reset by peer") {
		return true
	}

	// Default: don't retry unknown errors
	return false
}

// transcribeFileWithRetry calls the Whisper API with exponential backoff retry.
// Only retries transient failures (5xx, timeouts, network errors).
// Non-retryable errors (400, 401) fail immediately.
// maxAttempts is the total number of attempts (e.g., 4 = 1 initial + 3 retries).
// Backoff: 1s, 4s, 16s (exponential with base 4).
func (p *Pool) transcribeFileWithRetry(ctx context.Context, path, originalName string, maxAttempts int) (*audio.TranscriptionResult, error) {
	var lastErr error
	for attempt := 0; attempt < maxAttempts; attempt++ {
		if attempt > 0 {
			backoff := time.Duration(1<<(2*uint(attempt-1))) * time.Second // 1s, 4s, 16s
			log.Printf("🔄 Whisper retry %d/%d for %s (backoff %v)", attempt, maxAttempts, originalName, backoff)
			select {
			case <-time.After(backoff):
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		}

		file, err := os.Open(path)
		if err != nil {
			return nil, fmt.Errorf("failed to open audio file: %w", err)
		}
		uploadName := whisperUploadFilename(path, originalName)
		if attempt == 0 {
			log.Printf("📝 Whisper upload prepared: %s as %s", filepath.Base(path), uploadName)
		}
		result, err := p.audioTranscriber.Transcribe(ctx, file, uploadName)
		file.Close()
		if err == nil {
			if attempt > 0 {
				log.Printf("✅ Whisper succeeded on retry %d for %s", attempt, originalName)
			}
			return result, nil
		}
		lastErr = err
		log.Printf("⚠️  Whisper attempt %d/%d failed for %s: %v", attempt+1, maxAttempts, originalName, err)

		// Don't retry non-transient errors (4xx, bad format, etc)
		if !isRetryableError(err) {
			log.Printf("❌ Non-retryable error, failing immediately: %v", err)
			return nil, err
		}
	}
	return nil, fmt.Errorf("all %d Whisper attempts failed: %w", maxAttempts, lastErr)
}

func sanitizeTranscriptionResult(result *audio.TranscriptionResult) (string, []audio.TranscriptionSegment, int) {
	if result == nil {
		return "", nil, 0
	}
	return sanitizeStitchedTranscription(result.Text, result.Segments)
}

func sanitizeStitchedTranscription(text string, segments []audio.TranscriptionSegment) (string, []audio.TranscriptionSegment, int) {
	if len(segments) == 0 {
		return strings.TrimSpace(text), nil, 0
	}

	cleanedSegments, removed := removeRepeatedSegmentRuns(segments)
	if removed == 0 {
		return strings.TrimSpace(text), segments, 0
	}
	return transcriptionTextFromSegments(cleanedSegments), cleanedSegments, removed
}

func removeRepeatedSegmentRuns(segments []audio.TranscriptionSegment) ([]audio.TranscriptionSegment, int) {
	if len(segments) == 0 {
		return nil, 0
	}

	cleaned := make([]audio.TranscriptionSegment, 0, len(segments))
	removed := 0
	for i := 0; i < len(segments); {
		key := normalizedSegmentKey(segments[i].Text)
		if key == "" {
			cleaned = append(cleaned, segments[i])
			i++
			continue
		}

		j := i + 1
		for j < len(segments) && normalizedSegmentKey(segments[j].Text) == key {
			j++
		}

		run := segments[i:j]
		if shouldCollapseRepeatedSegmentRun(run, key) {
			// Keep one occurrence so the transcript still reflects that the phrase was
			// heard, but remove the synthetic loop that Whisper often emits over
			// unclear/silent audio.
			cleaned = append(cleaned, run[0])
			removed += len(run) - 1
		} else {
			cleaned = append(cleaned, run...)
		}
		i = j
	}

	return cleaned, removed
}

func shouldCollapseRepeatedSegmentRun(run []audio.TranscriptionSegment, key string) bool {
	if len(run) < repeatedSegmentRunMin {
		return false
	}

	phraseWords := strings.Fields(key)
	if len(phraseWords) == 0 {
		return false
	}

	highCompression := 0
	highNoSpeech := 0
	for _, segment := range run {
		if segment.CompressionRatio > 2.4 {
			highCompression++
		}
		if segment.NoSpeechProb > 0.5 {
			highNoSpeech++
		}
	}

	// Exact short-phrase runs are the classic Whisper failure shape seen in
	// long phone recordings: one phrase repeated once per second for tens of
	// seconds, often with high compression/no-speech probabilities. Natural
	// conversations can repeat a word a few times, so only collapse short runs
	// when they are very long or carry clear Whisper instability signals.
	if len(phraseWords) <= repeatedSegmentPhraseWordLimit {
		return len(run) >= repeatedSegmentLongRunMin || highCompression*3 >= len(run) || highNoSpeech*3 >= len(run)
	}

	return highCompression*2 >= len(run) || highNoSpeech*2 >= len(run)
}

func normalizedSegmentKey(text string) string {
	return strings.Join(normalizedTranscriptWords(text), " ")
}

func transcriptionTextFromSegments(segments []audio.TranscriptionSegment) string {
	var builder strings.Builder
	var previous audio.TranscriptionSegment
	hasPrevious := false

	for _, segment := range segments {
		text := strings.TrimSpace(segment.Text)
		if text == "" {
			continue
		}

		if builder.Len() > 0 {
			if hasPrevious && isLikelyChunkBoundary(previous, segment) {
				builder.WriteString("\n\n")
			} else {
				builder.WriteByte(' ')
			}
		}
		builder.WriteString(text)
		previous = segment
		hasPrevious = true
	}

	return strings.TrimSpace(builder.String())
}

func isLikelyChunkBoundary(previous, current audio.TranscriptionSegment) bool {
	// Whisper segment timestamps restart from zero for each chunk. If the stitched
	// segment stream jumps backward substantially, preserve the paragraph break
	// that the multi-chunk transcript originally had between chunks.
	if previous.End <= 0 || current.End <= current.Start {
		return false
	}
	return current.Start+2 < previous.End
}

func validateTranscriptionQuality(text string, duration float64, segments []audio.TranscriptionSegment) error {
	words := normalizedTranscriptWords(text)
	if len(words) >= 80 {
		// Check for local repetition instead of whole-transcript repetition. Long,
		// real meetings naturally reuse phrases across hours, but hallucinations tend
		// to loop the same words within a short window.
		minLocalUniqueRatio := minWindowUniqueRatio(words, 220)
		fourGramCoverage := maxWindowRepeatedNGramCoverage(words, 4, 220)
		sixGramCoverage := maxWindowRepeatedNGramCoverage(words, 6, 220)
		if minLocalUniqueRatio < 0.16 && (fourGramCoverage >= 0.50 || sixGramCoverage >= 0.45) {
			return fmt.Errorf("the output looked highly repetitive/hallucinated instead of like natural speech")
		}
	}

	if duration >= 5*60 && len(words) < 15 {
		return fmt.Errorf("almost no speech was detected in a long recording")
	}

	checkedSegments := 0
	badCompression := 0
	badLogprob := 0
	badNoSpeech := 0
	for _, segment := range segments {
		if strings.TrimSpace(segment.Text) == "" {
			continue
		}
		checkedSegments++
		if segment.CompressionRatio > 2.4 {
			badCompression++
		}
		if segment.AvgLogprob < -1.0 {
			badLogprob++
		}
		if segment.NoSpeechProb > 0.8 && segment.AvgLogprob < -1.0 {
			badNoSpeech++
		}
	}
	if checkedSegments >= 3 {
		if badCompression*2 >= checkedSegments {
			return fmt.Errorf("Whisper reported unstable compression on most transcript segments")
		}
		if badLogprob*3 >= checkedSegments*2 {
			return fmt.Errorf("Whisper reported low confidence on most transcript segments")
		}
		if badNoSpeech*2 >= checkedSegments {
			return fmt.Errorf("Whisper treated most segments as likely silence")
		}
	}

	return nil
}

func normalizedTranscriptWords(text string) []string {
	return strings.FieldsFunc(strings.ToLower(text), func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	})
}

func uniqueWordRatio(words []string) float64 {
	if len(words) == 0 {
		return 0
	}
	seen := make(map[string]struct{}, len(words))
	for _, word := range words {
		seen[word] = struct{}{}
	}
	return float64(len(seen)) / float64(len(words))
}

func minWindowUniqueRatio(words []string, windowSize int) float64 {
	if len(words) == 0 {
		return 0
	}
	minRatio := 1.0
	forEachWordWindow(words, windowSize, func(window []string) {
		if len(window) < 80 {
			return
		}
		if ratio := uniqueWordRatio(window); ratio < minRatio {
			minRatio = ratio
		}
	})
	return minRatio
}

func maxWindowRepeatedNGramCoverage(words []string, n, windowSize int) float64 {
	maxCoverage := 0.0
	forEachWordWindow(words, windowSize, func(window []string) {
		if len(window) < 80 {
			return
		}
		if coverage := repeatedNGramCoverage(window, n); coverage > maxCoverage {
			maxCoverage = coverage
		}
	})
	return maxCoverage
}

func forEachWordWindow(words []string, windowSize int, visit func([]string)) {
	if windowSize <= 0 || len(words) <= windowSize {
		visit(words)
		return
	}

	step := windowSize / 2
	if step <= 0 {
		step = windowSize
	}
	for start := 0; start < len(words); start += step {
		end := start + windowSize
		if end >= len(words) {
			// Always evaluate the final full-size tail window. A short partial
			// tail under-represents repetition density near the end of long audio.
			visit(words[len(words)-windowSize:])
			return
		}
		visit(words[start:end])
	}
}

func repeatedNGramCoverage(words []string, n int) float64 {
	if n <= 0 || len(words) < n {
		return 0
	}
	counts := make(map[string]int, len(words)-n+1)
	for i := 0; i <= len(words)-n; i++ {
		counts[strings.Join(words[i:i+n], " ")]++
	}

	// Measure all words covered by any repeated n-gram, not only the single most
	// common phrase. Hallucinations can rotate between a few repeated patterns,
	// so max-count-only coverage can under-report obvious repetitive output.
	covered := make([]bool, len(words))
	coveredCount := 0
	for i := 0; i <= len(words)-n; i++ {
		gram := strings.Join(words[i:i+n], " ")
		if counts[gram] <= 1 {
			continue
		}
		for j := i; j < i+n; j++ {
			if !covered[j] {
				covered[j] = true
				coveredCount++
			}
		}
	}
	return float64(coveredCount) / float64(len(words))
}

func pickDominantLanguage(counts map[string]int) string {
	if len(counts) == 0 {
		return ""
	}
	bestLang := ""
	bestCount := 0
	for lang, count := range counts {
		if count > bestCount {
			bestLang = lang
			bestCount = count
		}
	}
	return bestLang
}

func bytesToMB(bytes int64) float64 {
	return float64(bytes) / (1024 * 1024)
}

func splitAudioForWhisper(ctx context.Context, inputPath string, segmentSeconds int) ([]string, error) {
	baseDir := filepath.Dir(inputPath)
	baseName := strings.TrimSuffix(filepath.Base(inputPath), filepath.Ext(inputPath))
	pattern := filepath.Join(baseDir, fmt.Sprintf("%s.part-%%04d%s", baseName, whisperPreparedExtension))

	cmdCtx, cancel := context.WithTimeout(ctx, whisperFFmpegTimeout)
	defer cancel()

	cmd := exec.CommandContext(
		cmdCtx,
		"ffmpeg",
		"-nostdin",
		"-hide_banner",
		"-loglevel", "error",
		"-y",
		"-i", inputPath,
		"-map", "0:a:0",
		"-ac", "1",
		"-ar", "16000",
		"-c:a", "libmp3lame",
		"-b:a", whisperPreparedBitrate,
		"-f", "segment",
		"-segment_format", "mp3",
		"-segment_time", fmt.Sprintf("%d", segmentSeconds),
		"-reset_timestamps", "1",
		pattern,
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		if errors.Is(cmdCtx.Err(), context.DeadlineExceeded) && !errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return nil, fmt.Errorf("ffmpeg segment timed out after %s", whisperFFmpegTimeout)
		}
		return nil, fmt.Errorf("ffmpeg segment failed: %v (%s)", err, string(out))
	}

	globPattern := filepath.Join(baseDir, fmt.Sprintf("%s.part-*%s", baseName, whisperPreparedExtension))
	parts, err := filepath.Glob(globPattern)
	if err != nil {
		return nil, fmt.Errorf("glob segment outputs failed: %w", err)
	}
	if len(parts) == 0 {
		return nil, fmt.Errorf("no segment outputs created")
	}
	sort.Strings(parts)
	return parts, nil
}

func transcodeForWhisper(ctx context.Context, inputPath, outputPath string, onProgress func(int)) error {
	cmdCtx, cancel := context.WithTimeout(ctx, whisperFFmpegTimeout)
	defer cancel()

	durationSeconds, probeErr := probeMediaDuration(ctx, inputPath)
	if probeErr != nil || durationSeconds <= 0 {
		log.Printf("⚠️  ffprobe duration unavailable for %s; using elapsed transcode progress fallback", filepath.Base(inputPath))
	}

	cmd := exec.CommandContext(
		cmdCtx,
		"ffmpeg",
		"-nostdin",
		"-hide_banner",
		"-loglevel", "error",
		"-progress", "pipe:1",
		"-nostats",
		"-y",
		"-i", inputPath,
		"-map", "0:a:0",
		"-ac", "1",
		"-ar", "16000",
		"-c:a", "libmp3lame",
		"-b:a", whisperPreparedBitrate,
		"-f", "mp3",
		outputPath,
	)

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("ffmpeg progress pipe failed: %w", err)
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("ffmpeg transcode failed to start: %w", err)
	}

	lastProgress := 25
	progressMu := sync.Mutex{}
	recordProgress := func(progress int) {
		if onProgress == nil {
			return
		}
		if progress > 34 {
			progress = 34
		}
		shouldNotify := false
		progressMu.Lock()
		if progress > lastProgress {
			lastProgress = progress
			shouldNotify = true
		}
		progressMu.Unlock()
		if shouldNotify {
			onProgress(progress)
		}
	}

	progressDone := make(chan struct{})
	go func() {
		defer close(progressDone)
		scanner := bufio.NewScanner(stdout)
		for scanner.Scan() {
			if durationSeconds <= 0 {
				continue
			}
			line := scanner.Text()
			value, ok := strings.CutPrefix(line, "out_time_ms=")
			if !ok {
				// ffmpeg progress historically reports microseconds under both key names.
				value, ok = strings.CutPrefix(line, "out_time_us=")
			}
			if !ok {
				continue
			}
			microseconds, err := strconv.ParseFloat(strings.TrimSpace(value), 64)
			if err != nil {
				continue
			}
			fraction := (microseconds / 1_000_000) / durationSeconds
			progress := 25 + int(fraction*9)
			recordProgress(progress)
		}
	}()

	heartbeatDone := make(chan struct{})
	go func() {
		defer close(heartbeatDone)
		if durationSeconds > 0 {
			return
		}
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-progressDone:
				return
			case <-cmdCtx.Done():
				return
			case <-ticker.C:
				progressMu.Lock()
				nextProgress := lastProgress + 1
				progressMu.Unlock()
				if nextProgress < 34 {
					recordProgress(nextProgress)
				}
			}
		}
	}()

	<-progressDone
	<-heartbeatDone
	err = cmd.Wait()
	if err != nil {
		if errors.Is(cmdCtx.Err(), context.DeadlineExceeded) && !errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return fmt.Errorf("ffmpeg transcode timed out after %s", whisperFFmpegTimeout)
		}
		return fmt.Errorf("ffmpeg transcode failed: %v (%s)", err, stderr.String())
	}
	progressMu.Lock()
	needsFinalProgress := lastProgress < 34
	progressMu.Unlock()
	if needsFinalProgress {
		recordProgress(34)
	}
	return nil
}

func probeMediaDuration(ctx context.Context, inputPath string) (float64, error) {
	cmdCtx, cancel := context.WithTimeout(ctx, whisperProbeTimeout)
	defer cancel()

	cmd := exec.CommandContext(
		cmdCtx,
		"ffprobe",
		"-v", "error",
		"-show_entries", "format=duration",
		"-of", "default=noprint_wrappers=1:nokey=1",
		inputPath,
	)
	out, err := cmd.Output()
	if err != nil {
		return 0, err
	}
	duration, err := strconv.ParseFloat(strings.TrimSpace(string(out)), 64)
	if err != nil || duration <= 0 {
		return 0, err
	}
	return duration, nil
}
