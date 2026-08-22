package database

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

const backgroundJobColumns = `
	id, job_type, resource_id, payload, status, attempts, max_attempts,
	run_at, locked_by, locked_at, lease_expires_at, started_at,
	completed_at, last_error, created_at, updated_at
`

var ErrAudioSummaryNotQueueable = errors.New("audio summary is already active or audio is not completed")
var ErrAudioFormattingNotQueueable = errors.New("transcript formatting is already active or audio is not completed")

type audioTranscriptFormattingPayload struct {
	AudioID string `json:"audio_id"`
}

// marshalAudioTranscriptFormattingPayload builds the durable job payload in Go
// instead of asking PostgreSQL to reinterpret the resource UUID as text. Keeping
// the UUID and JSON parameters separate avoids ambiguous parameter inference in
// both PostgreSQL's simple and extended query protocols.
func marshalAudioTranscriptFormattingPayload(audioID string) (string, error) {
	payload, err := json.Marshal(audioTranscriptFormattingPayload{AudioID: audioID})
	if err != nil {
		return "", fmt.Errorf("marshal transcript formatting payload: %w", err)
	}
	return string(payload), nil
}

// EnqueueBackgroundJob persists work before waking an in-process worker.
// An active partial unique index makes repeated recovery/submission idempotent.
// If a database trigger already created a queued outbox row, this call refreshes
// its payload (notably with a local upload path) instead of creating a duplicate.
func (db *DB) EnqueueBackgroundJob(ctx context.Context, jobType, resourceID string, payload []byte) (bool, error) {
	if len(payload) == 0 {
		payload = []byte(`{}`)
	}
	var id string
	err := db.QueryRowContext(ctx, `
		INSERT INTO background_jobs (job_type, resource_id, payload)
		VALUES ($1, $2, $3::jsonb)
		ON CONFLICT (job_type, resource_id)
			WHERE status IN ('queued', 'running')
		DO UPDATE SET
			payload = EXCLUDED.payload,
			updated_at = NOW()
		WHERE background_jobs.status = 'queued'
		RETURNING id`,
		// JSON must cross database/sql as text. A []byte is encoded as bytea by
		// pgx's simple protocol, and its hex representation is not valid JSON.
		jobType, resourceID, string(payload),
	).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("enqueue background job: %w", err)
	}
	return true, nil
}

// QueueAudioSummary stores the requested model/length payload in the same
// transaction that exposes the pending summary state. The table trigger creates
// the outbox row; this statement replaces its default recovery payload before
// either change can become visible to a worker.
func (db *DB) QueueAudioSummary(
	ctx context.Context,
	audio *models.AudioTranscription,
	payload []byte,
) error {
	if len(payload) == 0 {
		return fmt.Errorf("audio summary payload is required")
	}
	if len(audio.SummaryEvidence) == 0 {
		audio.SummaryEvidence = []byte(`{}`)
	}
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin audio summary queue transaction: %w", err)
	}
	defer tx.Rollback()

	result, err := tx.ExecContext(ctx, `
		UPDATE audio_transcriptions
		SET content_type = $2, summary_text = $3, key_points = $4,
			action_items = $5, decisions = $6, summary_model = $7,
			summary_length = $8, summary_status = $9, summary_evidence = $10,
			summary_error_message = $11
		WHERE id = $1 AND status = 'completed'
		  AND summary_status NOT IN ('pending', 'processing')`,
		audio.ID,
		audio.ContentType,
		audio.SummaryText,
		audio.KeyPoints,
		audio.ActionItems,
		audio.Decisions,
		audio.SummaryModel,
		audio.SummaryLength,
		audio.SummaryStatus,
		audio.SummaryEvidence,
		audio.SummaryErrorMessage,
	)
	if err != nil {
		return fmt.Errorf("mark audio summary pending: %w", err)
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		return ErrAudioSummaryNotQueueable
	}

	_, err = tx.ExecContext(ctx, `
		INSERT INTO background_jobs (job_type, resource_id, payload)
		VALUES ('audio_summary', $1, $2::jsonb)
		ON CONFLICT (job_type, resource_id)
			WHERE status IN ('queued', 'running')
		DO UPDATE SET payload = EXCLUDED.payload, updated_at = NOW()
		WHERE background_jobs.status = 'queued'`,
		audio.ID, string(payload),
	)
	if err != nil {
		return fmt.Errorf("store audio summary job payload: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit audio summary queue transaction: %w", err)
	}
	return nil
}

// QueueAudioTranscriptFormatting atomically exposes the pending UI state and
// persists its durable job. Completed formatting can be requested again after
// a formatter upgrade; simultaneous requests remain idempotent.
func (db *DB) QueueAudioTranscriptFormatting(ctx context.Context, audioID string) error {
	payload, err := marshalAudioTranscriptFormattingPayload(audioID)
	if err != nil {
		return err
	}

	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin transcript formatting queue transaction: %w", err)
	}
	defer tx.Rollback()

	result, err := tx.ExecContext(ctx, `
		UPDATE audio_transcriptions
		SET formatting_status = 'pending',
			formatted_transcript_text = '',
			formatting_model = '',
			formatting_version = '',
			formatting_error_message = ''
		WHERE id = $1
		  AND status = 'completed'
		  AND transcript_text <> ''
		  AND formatting_status NOT IN ('pending', 'processing')`, audioID)
	if err != nil {
		return fmt.Errorf("mark transcript formatting pending: %w", err)
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("inspect transcript formatting queue update: %w", err)
	}
	if rows == 0 {
		return ErrAudioFormattingNotQueueable
	}

	_, err = tx.ExecContext(ctx, `
		INSERT INTO background_jobs (job_type, resource_id, payload)
		VALUES ('audio_transcript_formatting', $1, $2::jsonb)
		ON CONFLICT (job_type, resource_id)
			WHERE status IN ('queued', 'running')
		DO UPDATE SET payload = EXCLUDED.payload, updated_at = NOW()
		WHERE background_jobs.status = 'queued'`, audioID, payload)
	if err != nil {
		return fmt.Errorf("store transcript formatting job: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit transcript formatting queue transaction: %w", err)
	}
	return nil
}

func (db *DB) StartAudioTranscriptFormatting(ctx context.Context, audioID string) (bool, error) {
	result, err := db.ExecContext(ctx, `
		UPDATE audio_transcriptions
		SET formatting_status = 'processing', formatting_error_message = ''
		WHERE id = $1 AND status = 'completed'
		  AND formatting_status IN ('pending', 'processing')`, audioID)
	if err != nil {
		return false, fmt.Errorf("start transcript formatting: %w", err)
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("inspect transcript formatting start update: %w", err)
	}
	return rows > 0, nil
}

func (db *DB) CompleteAudioTranscriptFormatting(ctx context.Context, audioID, text, model, version string) error {
	result, err := db.ExecContext(ctx, `
		UPDATE audio_transcriptions
		SET formatted_transcript_text = $2,
			formatting_status = 'completed',
			formatting_model = $3,
			formatting_version = $4,
			formatting_error_message = ''
		WHERE id = $1 AND status = 'completed'
		  AND formatting_status IN ('pending', 'processing')`,
		audioID, text, model, version)
	if err != nil {
		return fmt.Errorf("complete transcript formatting: %w", err)
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("inspect transcript formatting completion update: %w", err)
	}
	if rows == 0 {
		return fmt.Errorf("transcript formatting is no longer active")
	}
	return nil
}

func (db *DB) FailAudioTranscriptFormatting(ctx context.Context, audioID, message string) error {
	result, err := db.ExecContext(ctx, `
		UPDATE audio_transcriptions
		SET formatted_transcript_text = '',
			formatting_status = 'failed',
			formatting_model = '',
			formatting_version = '',
			formatting_error_message = $2
		WHERE id = $1 AND status = 'completed'
		  AND formatting_status IN ('pending', 'processing')`, audioID, message)
	if err != nil {
		return fmt.Errorf("fail transcript formatting: %w", err)
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("inspect transcript formatting failure update: %w", err)
	}
	if rows == 0 {
		return fmt.Errorf("transcript formatting is no longer active")
	}
	return nil
}

// ClaimBackgroundJob leases the oldest ready job without blocking other worker
// processes. Expired running jobs are reclaimable after a process crash.
func (db *DB) ClaimBackgroundJob(ctx context.Context, workerID string, lease time.Duration) (*models.BackgroundJob, error) {
	if lease <= 0 {
		lease = 5 * time.Minute
	}
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("begin background job claim: %w", err)
	}
	defer tx.Rollback()

	var job models.BackgroundJob
	err = tx.GetContext(ctx, &job, `
		SELECT `+backgroundJobColumns+`
		FROM background_jobs
		WHERE (
			status = 'queued'
			AND run_at <= NOW()
			AND attempts < max_attempts
		) OR (
			status = 'running'
			AND lease_expires_at < NOW()
		)
		ORDER BY
			CASE WHEN status = 'queued' THEN 0 ELSE 1 END,
			run_at ASC,
			created_at ASC
		FOR UPDATE SKIP LOCKED
		LIMIT 1`)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("select background job: %w", err)
	}

	err = tx.GetContext(ctx, &job, `
		UPDATE background_jobs
		SET status = 'running',
			attempts = attempts + 1,
			locked_by = $2,
			locked_at = NOW(),
			lease_expires_at = NOW() + ($3 * INTERVAL '1 millisecond'),
			started_at = COALESCE(started_at, NOW()),
			last_error = ''
		WHERE id = $1
		RETURNING `+backgroundJobColumns,
		job.ID, workerID, lease.Milliseconds(),
	)
	if err != nil {
		return nil, fmt.Errorf("lease background job: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit background job claim: %w", err)
	}
	return &job, nil
}

// NextBackgroundJobWake returns the earliest time currently deferred durable
// work can become claimable. A nil result means there is no queued or leased
// work, allowing event-driven workers to sleep without a recurring DB poll.
func (db *DB) NextBackgroundJobWake(ctx context.Context) (*time.Time, error) {
	var next sql.NullTime
	err := db.GetContext(ctx, &next, `
		SELECT MIN(wake_at)
		FROM (
			SELECT run_at AS wake_at
			FROM background_jobs
			WHERE status = 'queued' AND attempts < max_attempts
			UNION ALL
			SELECT lease_expires_at AS wake_at
			FROM background_jobs
			WHERE status = 'running' AND lease_expires_at IS NOT NULL
		) AS deferred_jobs`)
	if err != nil {
		return nil, fmt.Errorf("find next background job wake: %w", err)
	}
	if !next.Valid {
		return nil, nil
	}
	return &next.Time, nil
}

func (db *DB) HeartbeatBackgroundJob(ctx context.Context, jobID, workerID string, lease time.Duration) error {
	result, err := db.ExecContext(ctx, `
		UPDATE background_jobs
		SET lease_expires_at = NOW() + ($3 * INTERVAL '1 millisecond')
		WHERE id = $1 AND status = 'running' AND locked_by = $2`,
		jobID, workerID, lease.Milliseconds(),
	)
	if err != nil {
		return fmt.Errorf("heartbeat background job: %w", err)
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		return fmt.Errorf("background job lease is no longer owned")
	}
	return nil
}

// ExpireBackgroundJobLease makes canceled in-flight work immediately
// reclaimable during a graceful deploy instead of waiting for the full lease.
// The row stays running so attempts/max-attempts bookkeeping still describes
// what happened and the normal expired-lease claim path remains authoritative.
func (db *DB) ExpireBackgroundJobLease(ctx context.Context, jobID, workerID string) error {
	result, err := db.ExecContext(ctx, `
		UPDATE background_jobs
		SET lease_expires_at = NOW() - INTERVAL '1 second',
			updated_at = NOW()
		WHERE id = $1 AND status = 'running' AND locked_by = $2`,
		jobID, workerID,
	)
	if err != nil {
		return fmt.Errorf("expire background job lease: %w", err)
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		return fmt.Errorf("background job lease is no longer owned")
	}
	return nil
}

func (db *DB) CompleteBackgroundJob(ctx context.Context, jobID, workerID string) error {
	result, err := db.ExecContext(ctx, `
		UPDATE background_jobs
		SET status = 'completed',
			completed_at = NOW(),
			locked_by = NULL,
			locked_at = NULL,
			lease_expires_at = NULL,
			last_error = ''
		WHERE id = $1 AND status = 'running' AND locked_by = $2`,
		jobID, workerID,
	)
	if err != nil {
		return fmt.Errorf("complete background job: %w", err)
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		return fmt.Errorf("background job completion lost its lease")
	}
	return nil
}

func (db *DB) FailBackgroundJob(ctx context.Context, jobID, workerID, message string) error {
	result, err := db.ExecContext(ctx, `
		UPDATE background_jobs
		SET status = 'failed',
			completed_at = NOW(),
			locked_by = NULL,
			locked_at = NULL,
			lease_expires_at = NULL,
			last_error = $3
		WHERE id = $1 AND status = 'running' AND locked_by = $2`,
		jobID, workerID, message,
	)
	if err != nil {
		return fmt.Errorf("fail background job: %w", err)
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		// A specialized worker path may already have atomically failed its
		// resource and durable job. Treat that terminal acknowledgement as
		// idempotent while still reporting a lease actually owned elsewhere.
		var status string
		if err := db.GetContext(ctx, &status, `SELECT status FROM background_jobs WHERE id = $1`, jobID); err == nil && status == "failed" {
			return nil
		}
		return fmt.Errorf("background job failure lost its lease")
	}
	return nil
}

// RequeueBackgroundJob releases a retryable job while preserving its attempt
// count. Only the worker that owns the current lease may reschedule it.
func (db *DB) RequeueBackgroundJob(
	ctx context.Context,
	jobID, workerID, message string,
	delay time.Duration,
	resetAttempts bool,
) error {
	if delay < 0 {
		delay = 0
	}
	result, err := db.ExecContext(ctx, `
		UPDATE background_jobs
		SET status = 'queued',
			run_at = NOW() + ($3 * INTERVAL '1 millisecond'),
			attempts = CASE WHEN $5 THEN 0 ELSE attempts END,
			locked_by = NULL,
			locked_at = NULL,
			lease_expires_at = NULL,
			completed_at = NULL,
			last_error = $4
		WHERE id = $1 AND status = 'running' AND locked_by = $2`,
		jobID, workerID, delay.Milliseconds(), message, resetAttempts)
	if err != nil {
		return fmt.Errorf("requeue background job: %w", err)
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("inspect background job retry: %w", err)
	}
	if rows == 0 {
		return fmt.Errorf("background job retry lost its lease")
	}
	return nil
}

func (db *DB) CountQueuedBackgroundJobs(ctx context.Context) (int, error) {
	var count int
	if err := db.GetContext(ctx, &count, `
		SELECT COUNT(*)
		FROM background_jobs
		WHERE status = 'queued'
		   OR (status = 'running' AND lease_expires_at < NOW())`,
	); err != nil {
		return 0, fmt.Errorf("count queued background jobs: %w", err)
	}
	return count, nil
}
