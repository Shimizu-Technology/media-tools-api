package database

import (
	"context"
	"fmt"
	"time"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

func (db *DB) CreateAudioUploadSession(ctx context.Context, session *models.AudioUploadSession) error {
	query := `
		INSERT INTO audio_upload_sessions (
			object_key, original_name, content_type, size_bytes, user_id, api_key_id, expires_at
		)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		RETURNING id, status, created_at`

	return db.QueryRowContext(ctx, query,
		session.ObjectKey, session.OriginalName, session.ContentType, session.SizeBytes,
		session.UserID, session.APIKeyID, session.ExpiresAt,
	).Scan(&session.ID, &session.Status, &session.CreatedAt)
}

func (db *DB) GetAudioUploadSessionForActor(ctx context.Context, objectKey string, userID, apiKeyID *string) (*models.AudioUploadSession, error) {
	if userID == nil && apiKeyID == nil {
		return nil, fmt.Errorf("actor is required")
	}

	var session models.AudioUploadSession
	err := db.GetContext(ctx, &session, `
		SELECT id, object_key, original_name, content_type, size_bytes, user_id, api_key_id,
		       status, expires_at, created_at, completed_at
		FROM audio_upload_sessions
		WHERE object_key = $1
		  AND status = 'pending'
		  AND expires_at > NOW()
		  AND (($2::uuid IS NOT NULL AND user_id = $2)
		    OR ($3::uuid IS NOT NULL AND api_key_id = $3))`,
		objectKey, userID, apiKeyID,
	)
	if err != nil {
		return nil, fmt.Errorf("audio upload session not found: %w", err)
	}
	return &session, nil
}

func (db *DB) CompleteAudioUploadSession(ctx context.Context, id string) error {
	result, err := db.ExecContext(ctx, `
		UPDATE audio_upload_sessions
		SET status = 'completed', completed_at = $2
		WHERE id = $1 AND status = 'pending'`,
		id, time.Now().UTC(),
	)
	if err != nil {
		return fmt.Errorf("complete audio upload session: %w", err)
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		return fmt.Errorf("audio upload session not pending")
	}
	return nil
}
