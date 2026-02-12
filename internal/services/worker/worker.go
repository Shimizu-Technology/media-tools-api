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
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

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
	JobTranscriptExtraction  JobType = "transcript_extraction"
	JobSummaryGeneration     JobType = "summary_generation"
	JobAudioTranscription    JobType = "audio_transcription"
)

const whisperTargetBytes = 24 << 20 // Keep below 25MB hard limit to account for multipart overhead
const whisperInitialSegmentSeconds = 1800

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
	AudioS3Key   string `json:"audio_s3_key,omitempty"`
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
	audioStorage    *storage.S3
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

func (p *Pool) SetAudioStorage(as *storage.S3) {
	p.audioStorage = as
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

// SubmitBlocking adds a job to the queue and blocks until it can be queued
// or the provided context is canceled.
func (p *Pool) SubmitBlocking(ctx context.Context, job Job) error {
	select {
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

// RecoverAudioJobs requeues pending/processing audio jobs on startup.
func (p *Pool) RecoverAudioJobs(ctx context.Context, limit int) (int, error) {
	rows, err := p.db.ListRecoverableAudioTranscriptions(ctx, limit)
	if err != nil {
		return 0, err
	}
	requeued := 0
	for _, at := range rows {
		if at.Status == "completed" {
			continue
		}
		payload := AudioPayload{
			AudioID:      at.ID,
			AudioS3Key:   at.AudioS3Key,
			OriginalName: at.OriginalName,
		}
		payloadJSON, err := json.Marshal(payload)
		if err != nil {
			continue
		}
		job := Job{
			ID:        at.ID,
			Type:      JobAudioTranscription,
			Payload:   payloadJSON,
			CreatedAt: time.Now(),
		}
		if err := p.Submit(job); err == nil {
			requeued++
			_ = p.db.UpdateAudioProcessing(ctx, at.ID, "queued", 0)
		}
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

	if retryCount, err := p.db.IncrementAudioRetryCount(ctx, at.ID); err == nil {
		at.RetryCount = retryCount
	}

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

	var transcriptionParts []string
	if fileInfo.Size() > whisperTargetBytes {
		_ = p.db.UpdateAudioProcessing(ctx, at.ID, "transcoding", 25)
		compressedPath := payload.TempFilePath + ".whisper.ogg"
		if err := transcodeForWhisper(ctx, payload.TempFilePath, compressedPath); err != nil {
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

		log.Printf("🎚️  Transcoded large audio for Whisper: %s %.1fMB -> %.1fMB",
			payload.OriginalName,
			float64(fileInfo.Size())/(1024*1024),
			float64(compressedInfo.Size())/(1024*1024),
		)

		if compressedInfo.Size() > whisperTargetBytes {
			segmentSeconds := whisperInitialSegmentSeconds
			for {
				_ = p.db.UpdateAudioProcessing(ctx, at.ID, "chunking", 35)
				segmentPaths, err := splitAudioForWhisper(ctx, compressedPath, segmentSeconds)
				if err != nil {
					at.Status = "failed"
					at.ErrorMessage = "Failed to split long audio for transcription: " + err.Error()
					p.db.UpdateAudioTranscription(ctx, at)
					return fmt.Errorf("failed to split compressed audio: %w", err)
				}
				cleanupPaths = append(cleanupPaths, segmentPaths...)

				oversized := false
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
						break
					}
				}

				if !oversized {
					transcriptionParts = segmentPaths
					log.Printf("🧩 Split long audio into %d segment(s) at %ds each for Whisper", len(segmentPaths), segmentSeconds)
					break
				}

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
	}

	var transcriptText string
	var language string
	var duration float64

	if len(transcriptionParts) == 0 {
		_ = p.db.UpdateAudioProcessing(ctx, at.ID, "transcribing", 70)
		// Single-file transcription
		result, err := p.transcribeFile(ctx, transcriptionPath, payload.OriginalName)
		if err != nil {
			log.Printf("❌ Whisper transcription failed for %s: %v", payload.OriginalName, err)
			at.Status = "failed"
			at.ErrorMessage = err.Error()
			p.db.UpdateAudioTranscription(ctx, at)
			p.notifyWebhook("audio.failed", at)
			return fmt.Errorf("transcription failed: %w", err)
		}
		transcriptText = result.Text
		language = result.Language
		duration = result.Duration
	} else {
		partTexts := make([]string, 0, len(transcriptionParts))
		languageCounts := map[string]int{}
		for idx, partPath := range transcriptionParts {
			if len(transcriptionParts) > 0 {
				progress := 40 + int(float64(idx)/float64(len(transcriptionParts))*50)
				_ = p.db.UpdateAudioProcessing(ctx, at.ID, "transcribing", progress)
			}
			partName := fmt.Sprintf("%s.part.%03d", payload.OriginalName, idx+1)
			result, err := p.transcribeFile(ctx, partPath, partName)
			if err != nil {
				log.Printf("❌ Whisper chunk transcription failed (%s): %v", partName, err)
				at.Status = "failed"
				at.ErrorMessage = err.Error()
				p.db.UpdateAudioTranscription(ctx, at)
				p.notifyWebhook("audio.failed", at)
				return fmt.Errorf("chunk transcription failed (%s): %w", partName, err)
			}
			partTexts = append(partTexts, strings.TrimSpace(result.Text))
			duration += result.Duration
			if result.Language != "" {
				languageCounts[result.Language]++
			}
		}
		transcriptText = strings.TrimSpace(strings.Join(partTexts, "\n\n"))
		language = pickDominantLanguage(languageCounts)
	}

	// Update the record with results
	_ = p.db.UpdateAudioProcessing(ctx, at.ID, "stitching", 95)
	at.TranscriptText = transcriptText
	at.Language = language
	at.Duration = duration
	at.WordCount = audio.CountWords(transcriptText)
	at.Status = "completed"
	at.ProcessingStage = "completed"
	at.ProcessingProgress = 100

	if err := p.db.UpdateAudioTranscription(ctx, at); err != nil {
		log.Printf("⚠️  Failed to save audio transcription result: %v", err)
		return fmt.Errorf("failed to save transcription: %w", err)
	}

	p.notifyWebhook("audio.completed", at)
	log.Printf("✅ Audio transcription completed: %s (%s, %.0fs, %d words)",
		payload.OriginalName, language, duration, at.WordCount)

	return nil
}

func (p *Pool) transcribeFile(ctx context.Context, path, originalName string) (*audio.TranscriptionResult, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("failed to open audio file: %w", err)
	}
	defer file.Close()
	return p.audioTranscriber.Transcribe(ctx, file, originalName)
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

func splitAudioForWhisper(ctx context.Context, inputPath string, segmentSeconds int) ([]string, error) {
	baseDir := filepath.Dir(inputPath)
	baseName := strings.TrimSuffix(filepath.Base(inputPath), filepath.Ext(inputPath))
	pattern := filepath.Join(baseDir, fmt.Sprintf("%s.part-%%04d.ogg", baseName))

	cmd := exec.CommandContext(
		ctx,
		"ffmpeg",
		"-y",
		"-i", inputPath,
		"-ac", "1",
		"-ar", "16000",
		"-c:a", "libopus",
		"-b:a", "24k",
		"-f", "segment",
		"-segment_time", fmt.Sprintf("%d", segmentSeconds),
		"-reset_timestamps", "1",
		pattern,
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("ffmpeg segment failed: %v (%s)", err, string(out))
	}

	globPattern := filepath.Join(baseDir, fmt.Sprintf("%s.part-*.ogg", baseName))
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

func transcodeForWhisper(ctx context.Context, inputPath, outputPath string) error {
	cmd := exec.CommandContext(
		ctx,
		"ffmpeg",
		"-y",
		"-i", inputPath,
		"-ac", "1",
		"-ar", "16000",
		"-c:a", "libopus",
		"-b:a", "24k",
		outputPath,
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("ffmpeg transcode failed: %v (%s)", err, string(out))
	}
	return nil
}
