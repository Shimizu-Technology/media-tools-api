package database

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"github.com/jmoiron/sqlx"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

const mediaSegmentColumns = `
	id, item_type, item_id, ordinal, start_ms, end_ms, page_number, text, created_at
`

func validMediaItemType(itemType string) bool {
	switch itemType {
	case "transcript", "audio", "pdf":
		return true
	default:
		return false
	}
}

// ReplaceMediaSegments atomically replaces an item's source evidence.
func (db *DB) ReplaceMediaSegments(ctx context.Context, itemType, itemID string, segments []models.MediaSegment) error {
	if !validMediaItemType(itemType) {
		return fmt.Errorf("unsupported media item type %q", itemType)
	}
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin media segment replacement: %w", err)
	}
	defer tx.Rollback()

	if err := replaceMediaSegmentsTx(ctx, tx, itemType, itemID, segments); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit media segment replacement: %w", err)
	}
	return nil
}

func replaceMediaSegmentsTx(ctx context.Context, tx *sqlx.Tx, itemType, itemID string, segments []models.MediaSegment) error {
	// Serialise replacements for one polymorphic parent. Legacy backfills can be
	// triggered by chat and summary requests at the same time; without this
	// transaction-scoped lock both could delete, then collide on ordinal 0.
	if _, err := tx.ExecContext(ctx,
		`SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`,
		itemType+":"+itemID,
	); err != nil {
		return fmt.Errorf("lock media segment replacement: %w", err)
	}
	if _, err := tx.ExecContext(ctx,
		`DELETE FROM media_segments WHERE item_type = $1 AND item_id = $2`,
		itemType, itemID,
	); err != nil {
		return fmt.Errorf("delete existing media segments: %w", err)
	}

	const insert = `
		INSERT INTO media_segments (
			item_type, item_id, ordinal, start_ms, end_ms, page_number, text
		)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		RETURNING id, created_at`
	for index := range segments {
		segment := &segments[index]
		text := strings.TrimSpace(segment.Text)
		if text == "" {
			continue
		}
		segment.ItemType = itemType
		segment.ItemID = itemID
		segment.Ordinal = index
		segment.Text = text
		if err := tx.QueryRowContext(ctx, insert,
			segment.ItemType,
			segment.ItemID,
			segment.Ordinal,
			segment.StartMS,
			segment.EndMS,
			segment.PageNumber,
			segment.Text,
		).Scan(&segment.ID, &segment.CreatedAt); err != nil {
			return fmt.Errorf("insert media segment %d: %w", index, err)
		}
	}
	return nil
}

// CreatePDFExtractionWithSegments publishes the extracted document and its
// page-addressable evidence together. Readers can never observe a completed
// PDF whose citation targets have not been written yet.
func (db *DB) CreatePDFExtractionWithSegments(
	ctx context.Context,
	pdf *models.PDFExtraction,
	segments []models.MediaSegment,
) error {
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin PDF extraction completion: %w", err)
	}
	defer tx.Rollback()

	err = tx.QueryRowContext(ctx, `
		INSERT INTO pdf_extractions (
			filename, original_name, page_count, text_content, word_count,
			status, error_message, user_id, api_key_id
		)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
		RETURNING id, created_at`,
		pdf.Filename,
		pdf.OriginalName,
		pdf.PageCount,
		pdf.TextContent,
		pdf.WordCount,
		pdf.Status,
		pdf.ErrorMessage,
		pdf.UserID,
		pdf.APIKeyID,
	).Scan(&pdf.ID, &pdf.CreatedAt)
	if err != nil {
		return fmt.Errorf("insert PDF extraction: %w", err)
	}
	if err := replaceMediaSegmentsTx(ctx, tx, "pdf", pdf.ID, segments); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit PDF extraction completion: %w", err)
	}
	return nil
}

// CompleteTranscriptWithSegments makes the completed transcript and its
// evidence visible in one transaction.
func (db *DB) CompleteTranscriptWithSegments(ctx context.Context, transcript *models.Transcript, segments []models.MediaSegment) error {
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin transcript completion: %w", err)
	}
	defer tx.Rollback()

	err = tx.QueryRowContext(ctx, `
		UPDATE transcripts
		SET title = $2, channel_name = $3, duration = $4, language = $5,
			transcript_text = $6, word_count = $7, status = $8,
			error_message = $9, updated_at = NOW()
		WHERE id = $1 AND status IN ('pending', 'processing')
		RETURNING updated_at`,
		transcript.ID,
		transcript.Title,
		transcript.ChannelName,
		transcript.Duration,
		transcript.Language,
		transcript.TranscriptText,
		transcript.WordCount,
		transcript.Status,
		transcript.ErrorMessage,
	).Scan(&transcript.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("transcript is no longer active")
	}
	if err != nil {
		return fmt.Errorf("complete transcript: %w", err)
	}
	if err := replaceMediaSegmentsTx(ctx, tx, "transcript", transcript.ID, segments); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit transcript completion: %w", err)
	}
	return nil
}

// CompleteAudioTranscriptionWithSegments atomically saves the final transcript
// and its seekable evidence while respecting user cancellation.
func (db *DB) CompleteAudioTranscriptionWithSegments(ctx context.Context, audio *models.AudioTranscription, segments []models.MediaSegment) (bool, error) {
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return false, fmt.Errorf("begin audio completion: %w", err)
	}
	defer tx.Rollback()

	result, err := tx.ExecContext(ctx, `
		UPDATE audio_transcriptions
		SET duration = $2, language = $3, transcript_text = $4, word_count = $5,
			status = $6, error_message = $7,
			processing_stage = $8, processing_progress = $9, retry_count = $10,
			quality_warning = $11, omitted_ranges = $12
		WHERE id = $1 AND status IN ('pending', 'processing')`,
		audio.ID,
		audio.Duration,
		audio.Language,
		audio.TranscriptText,
		audio.WordCount,
		audio.Status,
		audio.ErrorMessage,
		audio.ProcessingStage,
		audio.ProcessingProgress,
		audio.RetryCount,
		audio.QualityWarning,
		audio.OmittedRanges,
	)
	if err != nil {
		return false, fmt.Errorf("complete audio transcription: %w", err)
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		return false, nil
	}
	if err := replaceMediaSegmentsTx(ctx, tx, "audio", audio.ID, segments); err != nil {
		return false, err
	}
	if err := tx.Commit(); err != nil {
		return false, fmt.Errorf("commit audio completion: %w", err)
	}
	return true, nil
}

// ListMediaSegments returns source evidence in playback/document order.
func (db *DB) ListMediaSegments(ctx context.Context, itemType, itemID string) ([]models.MediaSegment, error) {
	if !validMediaItemType(itemType) {
		return nil, fmt.Errorf("unsupported media item type %q", itemType)
	}
	var segments []models.MediaSegment
	if err := db.SelectContext(ctx, &segments, `
		SELECT `+mediaSegmentColumns+`
		FROM media_segments
		WHERE item_type = $1 AND item_id = $2
		ORDER BY ordinal ASC`,
		itemType, itemID,
	); err != nil {
		return nil, fmt.Errorf("list media segments: %w", err)
	}
	if segments == nil {
		segments = []models.MediaSegment{}
	}
	return segments, nil
}

// SearchMediaSegments returns the strongest full-text matches with one segment
// of surrounding context on either side. If the query has no searchable terms,
// it returns the opening evidence so the model still has grounded context.
func (db *DB) SearchMediaSegments(ctx context.Context, itemType, itemID, query string, limit int) ([]models.MediaSegment, error) {
	if !validMediaItemType(itemType) {
		return nil, fmt.Errorf("unsupported media item type %q", itemType)
	}
	if limit <= 0 || limit > 30 {
		limit = 12
	}

	query = strings.TrimSpace(query)
	if query == "" {
		return db.listOpeningSegments(ctx, itemType, itemID, limit)
	}

	var segments []models.MediaSegment
	err := db.SelectContext(ctx, &segments, `
		WITH ranked AS (
			SELECT ordinal,
			       ts_rank_cd(search_vector, websearch_to_tsquery('simple', $3)) AS rank
			FROM media_segments
			WHERE item_type = $1
			  AND item_id = $2
			  AND search_vector @@ websearch_to_tsquery('simple', $3)
			ORDER BY rank DESC, ordinal ASC
			LIMIT $4
		),
		neighbors AS (
			SELECT DISTINCT m.ordinal
			FROM media_segments AS m
			INNER JOIN ranked AS r
			    ON m.ordinal BETWEEN r.ordinal - 1 AND r.ordinal + 1
			WHERE m.item_type = $1 AND m.item_id = $2
		)
		SELECT `+mediaSegmentColumns+`
		FROM media_segments
		WHERE item_type = $1
		  AND item_id = $2
		  AND ordinal IN (SELECT ordinal FROM neighbors)
		ORDER BY ordinal ASC
		LIMIT $5`,
		itemType, itemID, query, max(1, limit/3), limit,
	)
	if err != nil {
		return nil, fmt.Errorf("search media segments: %w", err)
	}
	if len(segments) == 0 {
		return db.listOpeningSegments(ctx, itemType, itemID, limit)
	}
	return segments, nil
}

func (db *DB) listOpeningSegments(ctx context.Context, itemType, itemID string, limit int) ([]models.MediaSegment, error) {
	var segments []models.MediaSegment
	err := db.SelectContext(ctx, &segments, `
		SELECT `+mediaSegmentColumns+`
		FROM media_segments
		WHERE item_type = $1 AND item_id = $2
		ORDER BY ordinal ASC
		LIMIT $3`,
		itemType, itemID, limit,
	)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("list opening media segments: %w", err)
	}
	return segments, nil
}
