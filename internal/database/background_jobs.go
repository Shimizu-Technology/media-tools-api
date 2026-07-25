package database

import (
	"context"
	"database/sql"
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
		VALUES ($1, $2, $3)
		ON CONFLICT (job_type, resource_id)
			WHERE status IN ('queued', 'running')
		DO UPDATE SET
			payload = EXCLUDED.payload,
			updated_at = NOW()
		WHERE background_jobs.status = 'queued'
		RETURNING id`,
		jobType, resourceID, payload,
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
			summary_status = $8, summary_evidence = $9,
			summary_error_message = $10
		WHERE id = $1 AND status = 'completed'
		  AND summary_status NOT IN ('pending', 'processing')`,
		audio.ID,
		audio.ContentType,
		audio.SummaryText,
		audio.KeyPoints,
		audio.ActionItems,
		audio.Decisions,
		audio.SummaryModel,
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
		VALUES ('audio_summary', $1, $2)
		ON CONFLICT (job_type, resource_id)
			WHERE status IN ('queued', 'running')
		DO UPDATE SET payload = EXCLUDED.payload, updated_at = NOW()
		WHERE background_jobs.status = 'queued'`,
		audio.ID, payload,
	)
	if err != nil {
		return fmt.Errorf("store audio summary job payload: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit audio summary queue transaction: %w", err)
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
		return fmt.Errorf("background job failure lost its lease")
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
