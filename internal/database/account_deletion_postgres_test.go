package database

import (
	"context"
	"encoding/json"
	"sort"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestRequestAccountDeletionPurgesOwnedDataAndQueuesCleanup(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	clerkID := "user_" + uuid.NewString()
	email := uuid.NewString() + "@example.com"
	ownedObjectKey := "audio/" + uuid.NewString() + ".m4a"
	pendingObjectKey := "audio/" + uuid.NewString() + ".m4a"

	var userID string
	if err := db.QueryRowContext(ctx, `
		INSERT INTO users (email, password_hash, name, clerk_id)
		VALUES ($1, '', 'Deletion Test', $2) RETURNING id`, email, clerkID).Scan(&userID); err != nil {
		t.Fatalf("insert user: %v", err)
	}

	var apiKeyID string
	if err := db.QueryRowContext(ctx, `
		INSERT INTO api_keys (key_hash, key_prefix, name, user_id)
		VALUES ($1, 'mta_test...', 'Deletion key', $2) RETURNING id`, uuid.NewString(), userID).Scan(&apiKeyID); err != nil {
		t.Fatalf("insert API key: %v", err)
	}

	var transcriptID, audioID, pdfID string
	if err := db.QueryRowContext(ctx, `
		INSERT INTO transcripts (youtube_url, youtube_id, status, user_id)
		VALUES ('https://example.com/video', $1, 'completed', $2) RETURNING id`, uuid.NewString()[:12], userID).Scan(&transcriptID); err != nil {
		t.Fatalf("insert transcript: %v", err)
	}
	if err := db.QueryRowContext(ctx, `
		INSERT INTO audio_transcriptions (
			filename, original_name, status, audio_s3_key, api_key_id
		) VALUES ('owned.m4a', 'owned.m4a', 'completed', $1, $2)
		RETURNING id`, ownedObjectKey, apiKeyID).Scan(&audioID); err != nil {
		t.Fatalf("insert audio: %v", err)
	}
	if err := db.QueryRowContext(ctx, `
		INSERT INTO pdf_extractions (filename, original_name, user_id)
		VALUES ('owned.pdf', 'owned.pdf', $1) RETURNING id`, userID).Scan(&pdfID); err != nil {
		t.Fatalf("insert PDF: %v", err)
	}
	if _, err := db.ExecContext(ctx, `
		INSERT INTO audio_upload_sessions (
			object_key, original_name, size_bytes, user_id, expires_at
		) VALUES ($1, 'pending.m4a', 100, $2, NOW() + INTERVAL '7 days')`, pendingObjectKey, userID); err != nil {
		t.Fatalf("insert upload session: %v", err)
	}
	if _, err := db.ExecContext(ctx, `
		INSERT INTO collections (name, user_id) VALUES ('Owned', $1);
		INSERT INTO workspace_items (user_id, item_type, item_id) VALUES ($1, 'audio', $2);
		INSERT INTO media_item_preferences (user_id, item_type, item_id) VALUES ($1, 'audio', $2)`, userID, audioID); err != nil {
		t.Fatalf("insert account-owned metadata: %v", err)
	}
	var reportID string
	if err := db.QueryRowContext(ctx, `
		INSERT INTO ai_content_reports (
			target_type, target_id, subject_type, subject_id,
			user_id, category, content_snapshot
		) VALUES ('audio_summary', $1, 'audio', $1, $2, 'other', '{"summary_text":"Reported output"}')
		RETURNING id`, audioID, userID).Scan(&reportID); err != nil {
		t.Fatalf("insert AI content report: %v", err)
	}

	cleanupAfter := time.Now().UTC().Add(time.Hour)
	request, err := db.RequestAccountDeletion(ctx, userID, clerkID, cleanupAfter)
	if err != nil {
		t.Fatalf("RequestAccountDeletion() error = %v", err)
	}
	t.Cleanup(func() {
		_, _ = db.ExecContext(context.Background(), `DELETE FROM background_jobs WHERE resource_id = $1`, request.ID)
		_, _ = db.ExecContext(context.Background(), `DELETE FROM account_deletion_requests WHERE id = $1`, request.ID)
	})
	loadedRequest, err := db.GetAccountDeletionRequest(ctx, request.ID)
	if err != nil {
		t.Fatalf("GetAccountDeletionRequest() error = %v", err)
	}
	if loadedRequest.ClerkUserID == nil || *loadedRequest.ClerkUserID != clerkID {
		t.Fatalf("loaded Clerk user ID = %#v", loadedRequest.ClerkUserID)
	}

	for table, id := range map[string]string{
		"users":                userID,
		"api_keys":             apiKeyID,
		"transcripts":          transcriptID,
		"audio_transcriptions": audioID,
		"pdf_extractions":      pdfID,
		"ai_content_reports":   reportID,
	} {
		var count int
		query := "SELECT COUNT(*) FROM " + table + " WHERE id = $1"
		if err := db.GetContext(ctx, &count, query, id); err != nil {
			t.Fatalf("count %s: %v", table, err)
		}
		if count != 0 {
			t.Fatalf("%s row remained after deletion", table)
		}
	}

	var keys []string
	if err := json.Unmarshal(request.ObjectKeys, &keys); err != nil {
		t.Fatalf("decode object keys: %v", err)
	}
	expectedKeys := []string{ownedObjectKey, pendingObjectKey}
	sort.Strings(expectedKeys)
	if len(keys) != 2 || keys[0] != expectedKeys[0] || keys[1] != expectedKeys[1] {
		t.Fatalf("object keys = %#v", keys)
	}

	blocked, err := db.HasAccountDeletionTombstone(ctx, clerkID)
	if err != nil || !blocked {
		t.Fatalf("deletion tombstone = %v, %v", blocked, err)
	}
	var jobStatus string
	if err := db.GetContext(ctx, &jobStatus, `
		SELECT status FROM background_jobs
		WHERE job_type = 'account_deletion' AND resource_id = $1`, request.ID); err != nil {
		t.Fatalf("load deletion job: %v", err)
	}
	if jobStatus != "queued" {
		t.Fatalf("deletion job status = %q", jobStatus)
	}
	var deletionJobID string
	if err := db.GetContext(ctx, &deletionJobID, `
		UPDATE background_jobs
		SET status = 'running', attempts = max_attempts, locked_by = 'test-worker',
			locked_at = NOW(), lease_expires_at = NOW() + INTERVAL '1 minute'
		WHERE job_type = 'account_deletion' AND resource_id = $1
		RETURNING id`, request.ID); err != nil {
		t.Fatalf("exhaust deletion job attempts: %v", err)
	}
	if err := db.RequeueBackgroundJob(
		ctx, deletionJobID, "test-worker", "provider unavailable", time.Minute, true,
	); err != nil {
		t.Fatalf("durably requeue deletion job: %v", err)
	}
	var retried struct {
		Status   string `db:"status"`
		Attempts int    `db:"attempts"`
	}
	if err := db.GetContext(ctx, &retried, `
		SELECT status, attempts FROM background_jobs WHERE id = $1`, deletionJobID); err != nil {
		t.Fatalf("load requeued deletion job: %v", err)
	}
	if retried.Status != "queued" || retried.Attempts != 0 {
		t.Fatalf("requeued deletion job = %#v, want queued with reset attempts", retried)
	}
	if err := db.MarkAccountIdentityDeleted(ctx, request.ID); err != nil {
		t.Fatalf("MarkAccountIdentityDeleted() error = %v", err)
	}
	if err := db.CompleteAccountDeletion(ctx, request.ID); err != nil {
		t.Fatalf("CompleteAccountDeletion() error = %v", err)
	}
	completed, err := db.GetAccountDeletionRequest(ctx, request.ID)
	if err != nil {
		t.Fatalf("reload completed deletion: %v", err)
	}
	if completed.Status != "completed" || completed.ClerkUserID != nil || string(completed.ObjectKeys) != "[]" {
		t.Fatalf("completed deletion retained provider data: %#v", completed)
	}
}
