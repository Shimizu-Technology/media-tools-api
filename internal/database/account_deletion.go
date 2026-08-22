package database

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

var ErrAccountDeletionAlreadyRequested = errors.New("account deletion already requested")

const accountDeletionColumns = `
	id, app_user_id, clerk_user_id, clerk_user_hash, object_keys, status,
	cleanup_after, clerk_deleted_at, completed_at, last_error,
	requested_at, updated_at
`

func clerkUserHash(clerkUserID string) string {
	sum := sha256.Sum256([]byte(clerkUserID))
	return hex.EncodeToString(sum[:])
}

// HasAccountDeletionTombstone prevents a valid but already-issued Clerk token
// from recreating an application account after deletion was requested.
func (db *DB) HasAccountDeletionTombstone(ctx context.Context, clerkUserID string) (bool, error) {
	var exists bool
	if err := db.GetContext(ctx, &exists, `
		SELECT EXISTS (
			SELECT 1 FROM account_deletion_requests
			WHERE clerk_user_hash = $1
		)`, clerkUserHash(clerkUserID)); err != nil {
		return false, fmt.Errorf("check account deletion tombstone: %w", err)
	}
	return exists, nil
}

// RequestAccountDeletion atomically records the durable deletion request and
// removes every account-owned database row. Object storage and Clerk are
// completed asynchronously because both are external systems that can fail.
func (db *DB) RequestAccountDeletion(
	ctx context.Context,
	userID string,
	clerkUserID string,
	cleanupAfter time.Time,
) (*models.AccountDeletionRequest, error) {
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("begin account deletion: %w", err)
	}
	defer tx.Rollback()

	var storedClerkID sql.NullString
	if err := tx.GetContext(ctx, &storedClerkID, `
		SELECT clerk_id FROM users WHERE id = $1 FOR UPDATE`, userID); err != nil {
		return nil, fmt.Errorf("lock account for deletion: %w", err)
	}
	if !storedClerkID.Valid || storedClerkID.String == "" || storedClerkID.String != clerkUserID {
		return nil, fmt.Errorf("account is not linked to the authenticated Clerk identity")
	}

	if cleanupAfter.Before(time.Now().UTC()) {
		cleanupAfter = time.Now().UTC()
	}

	var objectKeys []string
	if err := tx.SelectContext(ctx, &objectKeys, `
		SELECT DISTINCT object_key
		FROM (
			SELECT audio_s3_key AS object_key
			FROM audio_transcriptions
			WHERE audio_s3_key <> ''
			  AND (user_id = $1 OR api_key_id IN (SELECT id FROM api_keys WHERE user_id = $1))
			UNION
			SELECT object_key
			FROM audio_upload_sessions
			WHERE user_id = $1 OR api_key_id IN (SELECT id FROM api_keys WHERE user_id = $1)
		) owned_objects
		WHERE object_key <> ''
		ORDER BY object_key`, userID); err != nil {
		return nil, fmt.Errorf("collect account storage objects: %w", err)
	}
	if objectKeys == nil {
		objectKeys = []string{}
	}
	encodedKeys, err := json.Marshal(objectKeys)
	if err != nil {
		return nil, fmt.Errorf("encode account storage objects: %w", err)
	}

	request := &models.AccountDeletionRequest{}
	err = tx.GetContext(ctx, request, `
		INSERT INTO account_deletion_requests (
			app_user_id, clerk_user_id, clerk_user_hash, object_keys, cleanup_after
		)
		VALUES ($1, $2, $3, $4::jsonb, $5)
		RETURNING `+accountDeletionColumns,
		userID, clerkUserID, clerkUserHash(clerkUserID), string(encodedKeys), cleanupAfter,
	)
	if err != nil {
		var existing string
		if lookupErr := tx.GetContext(ctx, &existing, `
			SELECT id FROM account_deletion_requests WHERE clerk_user_hash = $1`,
			clerkUserHash(clerkUserID)); lookupErr == nil {
			return nil, ErrAccountDeletionAlreadyRequested
		}
		return nil, fmt.Errorf("create account deletion request: %w", err)
	}

	// Snapshot every owned identifier before deleting anything. Temporary tables
	// keep the purge readable and ensure polymorphic rows cannot be orphaned.
	statements := []string{
		`CREATE TEMP TABLE delete_api_keys ON COMMIT DROP AS
			SELECT id FROM api_keys WHERE user_id = $1`,
		`CREATE TEMP TABLE delete_transcripts ON COMMIT DROP AS
			SELECT id, batch_id FROM transcripts
			WHERE user_id = $1 OR api_key_id IN (SELECT id FROM delete_api_keys)`,
		`CREATE TEMP TABLE delete_audio ON COMMIT DROP AS
			SELECT id FROM audio_transcriptions
			WHERE user_id = $1 OR api_key_id IN (SELECT id FROM delete_api_keys)`,
		`CREATE TEMP TABLE delete_pdfs ON COMMIT DROP AS
			SELECT id FROM pdf_extractions
			WHERE user_id = $1 OR api_key_id IN (SELECT id FROM delete_api_keys)`,
		`CREATE TEMP TABLE delete_summaries ON COMMIT DROP AS
			SELECT id FROM summaries WHERE transcript_id IN (SELECT id FROM delete_transcripts)`,
		`CREATE TEMP TABLE delete_batches ON COMMIT DROP AS
			SELECT id FROM batches
			WHERE user_id = $1
			   OR api_key_id IN (SELECT id FROM delete_api_keys)
			   OR id IN (SELECT batch_id FROM delete_transcripts WHERE batch_id IS NOT NULL)`,
	}
	for _, statement := range statements {
		var execErr error
		if strings.Contains(statement, "$1") {
			_, execErr = tx.ExecContext(ctx, statement, userID)
		} else {
			_, execErr = tx.ExecContext(ctx, statement)
		}
		if execErr != nil {
			return nil, fmt.Errorf("snapshot account data for deletion: %w", execErr)
		}
	}

	purgeStatements := []string{
		`DELETE FROM background_jobs WHERE
			(job_type = 'transcript_extraction' AND resource_id IN (SELECT id FROM delete_transcripts))
			OR (job_type = 'summary_generation' AND resource_id IN (SELECT id FROM delete_summaries))
			OR (job_type IN ('audio_transcription', 'audio_summary', 'audio_transcript_formatting')
				AND resource_id IN (SELECT id FROM delete_audio))`,
		`DELETE FROM collection_items WHERE
			(item_type = 'transcript' AND item_id IN (SELECT id FROM delete_transcripts))
			OR (item_type = 'audio' AND item_id IN (SELECT id FROM delete_audio))
			OR (item_type = 'pdf' AND item_id IN (SELECT id FROM delete_pdfs))`,
		`DELETE FROM transcript_chat_sessions WHERE
			user_id = $1 OR api_key_id IN (SELECT id FROM delete_api_keys)
			OR (item_type = 'transcript' AND item_id IN (SELECT id FROM delete_transcripts))
			OR (item_type = 'audio' AND item_id IN (SELECT id FROM delete_audio))
			OR (item_type = 'pdf' AND item_id IN (SELECT id FROM delete_pdfs))`,
		`DELETE FROM media_item_preferences WHERE
			user_id = $1 OR api_key_id IN (SELECT id FROM delete_api_keys)
			OR (item_type = 'youtube' AND item_id IN (SELECT id FROM delete_transcripts))
			OR (item_type = 'audio' AND item_id IN (SELECT id FROM delete_audio))
			OR (item_type = 'pdf' AND item_id IN (SELECT id FROM delete_pdfs))`,
		`DELETE FROM workspace_items WHERE user_id = $1
			OR (item_type = 'transcript' AND item_id IN (SELECT id FROM delete_transcripts))
			OR (item_type = 'audio' AND item_id IN (SELECT id FROM delete_audio))
			OR (item_type = 'pdf' AND item_id IN (SELECT id FROM delete_pdfs))`,
		`DELETE FROM collections WHERE user_id = $1 OR api_key_id IN (SELECT id FROM delete_api_keys)`,
		`DELETE FROM webhooks WHERE user_id = $1 OR api_key_id IN (SELECT id FROM delete_api_keys)`,
		`DELETE FROM audio_upload_sessions WHERE user_id = $1 OR api_key_id IN (SELECT id FROM delete_api_keys)`,
		`DELETE FROM transcripts WHERE id IN (SELECT id FROM delete_transcripts)`,
		`DELETE FROM audio_transcriptions WHERE id IN (SELECT id FROM delete_audio)`,
		`DELETE FROM pdf_extractions WHERE id IN (SELECT id FROM delete_pdfs)`,
		`DELETE FROM batches WHERE id IN (SELECT id FROM delete_batches)`,
		`DELETE FROM api_keys WHERE id IN (SELECT id FROM delete_api_keys)`,
		`DELETE FROM users WHERE id = $1`,
	}
	for _, statement := range purgeStatements {
		var execErr error
		if strings.Contains(statement, "$1") {
			_, execErr = tx.ExecContext(ctx, statement, userID)
		} else {
			_, execErr = tx.ExecContext(ctx, statement)
		}
		if execErr != nil {
			return nil, fmt.Errorf("purge account data: %w", execErr)
		}
	}

	if _, err := tx.ExecContext(ctx, `
		INSERT INTO background_jobs (
			job_type, resource_id, payload, max_attempts, run_at
		)
		VALUES ('account_deletion', $1, '{}'::jsonb, 12, NOW())`, request.ID); err != nil {
		return nil, fmt.Errorf("queue account deletion: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit account deletion: %w", err)
	}
	return request, nil
}

func (db *DB) GetAccountDeletionRequest(ctx context.Context, id string) (*models.AccountDeletionRequest, error) {
	var request models.AccountDeletionRequest
	if err := db.GetContext(ctx, &request, `
		SELECT `+accountDeletionColumns+`
		FROM account_deletion_requests WHERE id = $1`, id); err != nil {
		return nil, fmt.Errorf("get account deletion request: %w", err)
	}
	return &request, nil
}

func (db *DB) StartAccountDeletion(ctx context.Context, id string) error {
	_, err := db.ExecContext(ctx, `
		UPDATE account_deletion_requests
		SET status = 'processing', last_error = ''
		WHERE id = $1 AND status IN ('pending', 'processing', 'failed')`, id)
	return err
}

func (db *DB) MarkAccountIdentityDeleted(ctx context.Context, id string) error {
	_, err := db.ExecContext(ctx, `
		UPDATE account_deletion_requests
		SET clerk_deleted_at = COALESCE(clerk_deleted_at, NOW()), status = 'processing'
		WHERE id = $1`, id)
	return err
}

func (db *DB) RecordAccountDeletionError(ctx context.Context, id, message string) error {
	_, err := db.ExecContext(ctx, `
		UPDATE account_deletion_requests
		SET status = 'pending', last_error = $2
		WHERE id = $1 AND status <> 'completed'`, id, message)
	return err
}

func (db *DB) FailAccountDeletion(ctx context.Context, id, message string) error {
	_, err := db.ExecContext(ctx, `
		UPDATE account_deletion_requests
		SET status = 'failed', last_error = $2
		WHERE id = $1 AND status <> 'completed'`, id, message)
	return err
}

func (db *DB) CompleteAccountDeletion(ctx context.Context, id string) error {
	_, err := db.ExecContext(ctx, `
		UPDATE account_deletion_requests
		SET status = 'completed', completed_at = NOW(), clerk_user_id = NULL,
			object_keys = '[]'::jsonb, last_error = ''
		WHERE id = $1`, id)
	return err
}
