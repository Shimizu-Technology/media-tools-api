package database

import (
	"context"
	"fmt"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

func (db *DB) GetTranscriptForActor(ctx context.Context, id string, userID, apiKeyID *string) (*models.Transcript, error) {
	if userID == nil && apiKeyID == nil {
		return nil, fmt.Errorf("actor is required")
	}
	var t models.Transcript
	err := db.GetContext(ctx, &t, `
		SELECT * FROM transcripts
		WHERE id = $1
		  AND (($2::uuid IS NOT NULL AND user_id = $2)
		    OR ($3::uuid IS NOT NULL AND api_key_id = $3))`,
		id, userID, apiKeyID,
	)
	if err != nil {
		return nil, fmt.Errorf("transcript not found: %w", err)
	}
	return &t, nil
}

func (db *DB) GetTranscriptByYouTubeIDForActor(ctx context.Context, youtubeID string, userID, apiKeyID *string) (*models.Transcript, error) {
	if userID == nil && apiKeyID == nil {
		return nil, fmt.Errorf("actor is required")
	}
	var t models.Transcript
	err := db.GetContext(ctx, &t, `
		SELECT * FROM transcripts
		WHERE youtube_id = $1
		  AND (($2::uuid IS NOT NULL AND user_id = $2)
		    OR ($3::uuid IS NOT NULL AND api_key_id = $3))
		ORDER BY created_at DESC
		LIMIT 1`,
		youtubeID, userID, apiKeyID,
	)
	if err != nil {
		return nil, err
	}
	return &t, nil
}

func (db *DB) DeleteTranscriptForActor(ctx context.Context, id string, userID, apiKeyID *string) error {
	if userID == nil && apiKeyID == nil {
		return fmt.Errorf("actor is required")
	}
	result, err := db.ExecContext(ctx, `
		DELETE FROM transcripts
		WHERE id = $1
		  AND (($2::uuid IS NOT NULL AND user_id = $2)
		    OR ($3::uuid IS NOT NULL AND api_key_id = $3))`,
		id, userID, apiKeyID,
	)
	if err != nil {
		return fmt.Errorf("failed to delete transcript: %w", err)
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		return fmt.Errorf("transcript not found")
	}
	return nil
}

func (db *DB) GetAudioTranscriptionForActor(ctx context.Context, id string, userID, apiKeyID *string) (*models.AudioTranscription, error) {
	if userID == nil && apiKeyID == nil {
		return nil, fmt.Errorf("actor is required")
	}
	var at models.AudioTranscription
	query := fmt.Sprintf(`SELECT %s FROM audio_transcriptions
		WHERE id = $1
		  AND (($2::uuid IS NOT NULL AND user_id = $2)
		    OR ($3::uuid IS NOT NULL AND api_key_id = $3))`, audioTranscriptionSelectColumns)
	err := db.GetContext(ctx, &at, query, id, userID, apiKeyID)
	if err != nil {
		return nil, fmt.Errorf("audio transcription not found: %w", err)
	}
	return &at, nil
}

func (db *DB) DeleteAudioTranscriptionForActor(ctx context.Context, id string, userID, apiKeyID *string) error {
	if userID == nil && apiKeyID == nil {
		return fmt.Errorf("actor is required")
	}
	result, err := db.ExecContext(ctx, `
		DELETE FROM audio_transcriptions
		WHERE id = $1
		  AND (($2::uuid IS NOT NULL AND user_id = $2)
		    OR ($3::uuid IS NOT NULL AND api_key_id = $3))`,
		id, userID, apiKeyID,
	)
	if err != nil {
		return fmt.Errorf("failed to delete audio transcription: %w", err)
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		return fmt.Errorf("audio transcription not found")
	}
	return nil
}

func (db *DB) RenameAudioTranscriptionForActor(ctx context.Context, id string, userID, apiKeyID *string, name string) (*models.AudioTranscription, error) {
	if userID == nil && apiKeyID == nil {
		return nil, fmt.Errorf("actor is required")
	}
	query := fmt.Sprintf(`
		UPDATE audio_transcriptions
		SET original_name = $4
		WHERE id = $1
		  AND (($2::uuid IS NOT NULL AND user_id = $2)
		    OR ($3::uuid IS NOT NULL AND api_key_id = $3))
		RETURNING %s`, audioTranscriptionSelectColumns)

	var at models.AudioTranscription
	if err := db.GetContext(ctx, &at, query, id, userID, apiKeyID, name); err != nil {
		return nil, fmt.Errorf("audio transcription not found: %w", err)
	}
	return &at, nil
}

func (db *DB) GetPDFExtractionForActor(ctx context.Context, id string, userID, apiKeyID *string) (*models.PDFExtraction, error) {
	if userID == nil && apiKeyID == nil {
		return nil, fmt.Errorf("actor is required")
	}
	var pe models.PDFExtraction
	err := db.GetContext(ctx, &pe, `
		SELECT * FROM pdf_extractions
		WHERE id = $1
		  AND (($2::uuid IS NOT NULL AND user_id = $2)
		    OR ($3::uuid IS NOT NULL AND api_key_id = $3))`,
		id, userID, apiKeyID,
	)
	if err != nil {
		return nil, fmt.Errorf("pdf extraction not found: %w", err)
	}
	return &pe, nil
}

func (db *DB) DeletePDFExtractionForActor(ctx context.Context, id string, userID, apiKeyID *string) error {
	if userID == nil && apiKeyID == nil {
		return fmt.Errorf("actor is required")
	}
	result, err := db.ExecContext(ctx, `
		DELETE FROM pdf_extractions
		WHERE id = $1
		  AND (($2::uuid IS NOT NULL AND user_id = $2)
		    OR ($3::uuid IS NOT NULL AND api_key_id = $3))`,
		id, userID, apiKeyID,
	)
	if err != nil {
		return fmt.Errorf("failed to delete PDF extraction: %w", err)
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		return fmt.Errorf("PDF extraction not found")
	}
	return nil
}
