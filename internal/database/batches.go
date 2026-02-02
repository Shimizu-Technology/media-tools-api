// batches.go handles batch-related database operations (MTA-8).
//
// Go Pattern: We split database operations into multiple files for
// organization. Each file handles one "domain" — transcripts, summaries,
// API keys, and now batches. They all use the same *DB receiver.
package database

import (
	"context"
	"fmt"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

// CreateBatch inserts a new batch record.
// The batch starts in "pending" status with the given total count.
func (db *DB) CreateBatch(ctx context.Context, b *models.Batch) error {
	query := `
		INSERT INTO batches (status, total_count, completed_count, failed_count)
		VALUES ($1, $2, $3, $4)
		RETURNING id, created_at, updated_at`

	return db.QueryRowContext(ctx, query,
		b.Status, b.TotalCount, b.CompletedCount, b.FailedCount,
	).Scan(&b.ID, &b.CreatedAt, &b.UpdatedAt)
}

// GetBatch retrieves a batch by ID.
func (db *DB) GetBatch(ctx context.Context, id string) (*models.Batch, error) {
	var b models.Batch
	err := db.GetContext(ctx, &b, `SELECT * FROM batches WHERE id = $1`, id)
	if err != nil {
		return nil, fmt.Errorf("batch not found: %w", err)
	}
	return &b, nil
}

// GetTranscriptsByBatch returns all transcripts belonging to a batch.
// Go Pattern: This is a simple query with a WHERE clause on the foreign key.
// We order by created_at so the results are in the same order they were submitted.
func (db *DB) GetTranscriptsByBatch(ctx context.Context, batchID string) ([]models.Transcript, error) {
	var transcripts []models.Transcript
	err := db.SelectContext(ctx, &transcripts,
		`SELECT * FROM transcripts WHERE batch_id = $1 ORDER BY created_at ASC`, batchID)
	if err != nil {
		return nil, fmt.Errorf("failed to list batch transcripts: %w", err)
	}
	return transcripts, nil
}

// CreateTranscriptWithBatch inserts a transcript linked to a batch.
// Go Pattern: This is similar to CreateTranscript but includes the batch_id column.
// We could combine them into one function with an optional parameter, but having
// two explicit functions makes the intent clearer and avoids nil-pointer issues.
func (db *DB) CreateTranscriptWithBatch(ctx context.Context, t *models.Transcript) error {
	query := `
		INSERT INTO transcripts (youtube_url, youtube_id, title, channel_name, duration, language, transcript_text, word_count, status, error_message, batch_id)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
		RETURNING id, created_at, updated_at`

	return db.QueryRowContext(ctx, query,
		t.YouTubeURL, t.YouTubeID, t.Title, t.ChannelName,
		t.Duration, t.Language, t.TranscriptText, t.WordCount,
		t.Status, t.ErrorMessage, t.BatchID,
	).Scan(&t.ID, &t.CreatedAt, &t.UpdatedAt)
}

// UpdateBatchCounts recalculates the batch's progress counters by querying
// the actual transcript statuses. This is more reliable than incrementing
// counters — if a worker crashes mid-update, the counts self-heal on the
// next check.
//
// Go Pattern: Using a subquery to count statuses in one round-trip instead
// of multiple queries. The CASE/WHEN pattern is PostgreSQL's equivalent of
// a conditional count.
func (db *DB) UpdateBatchCounts(ctx context.Context, batchID string) error {
	query := `
		UPDATE batches SET
			completed_count = (SELECT COUNT(*) FROM transcripts WHERE batch_id = $1 AND status = 'completed'),
			failed_count = (SELECT COUNT(*) FROM transcripts WHERE batch_id = $1 AND status = 'failed'),
			status = CASE
				WHEN (SELECT COUNT(*) FROM transcripts WHERE batch_id = $1 AND status IN ('pending', 'processing')) = 0
					AND (SELECT COUNT(*) FROM transcripts WHERE batch_id = $1 AND status = 'failed') > 0
					AND (SELECT COUNT(*) FROM transcripts WHERE batch_id = $1 AND status = 'completed') = 0
				THEN 'failed'
				WHEN (SELECT COUNT(*) FROM transcripts WHERE batch_id = $1 AND status IN ('pending', 'processing')) = 0
				THEN 'completed'
				ELSE 'processing'
			END,
			updated_at = NOW()
		WHERE id = $1`

	_, err := db.ExecContext(ctx, query, batchID)
	if err != nil {
		return fmt.Errorf("failed to update batch counts: %w", err)
	}
	return nil
}
