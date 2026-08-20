package database

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/google/uuid"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

func openPostgresIntegrationDB(t *testing.T) *DB {
	t.Helper()
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	db, err := NewWithSimpleProtocol(databaseURL, true)
	if err != nil {
		t.Fatalf("connect to PostgreSQL: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if err := db.RunMigrations(filepath.Join("..", "..", "migrations")); err != nil {
		t.Fatalf("run migrations: %v", err)
	}
	return db
}

func insertTestAudio(t *testing.T, db *DB, status string) string {
	t.Helper()
	var id string
	err := db.QueryRowContext(context.Background(), `
		INSERT INTO audio_transcriptions (filename, original_name, status)
		VALUES ($1, $2, $3)
		RETURNING id`, uuid.NewString()+".m4a", "integration-test.m4a", status).Scan(&id)
	if err != nil {
		t.Fatalf("insert audio transcription: %v", err)
	}
	t.Cleanup(func() {
		_, _ = db.ExecContext(context.Background(), `DELETE FROM background_jobs WHERE resource_id = $1`, id)
		_, _ = db.ExecContext(context.Background(), `DELETE FROM media_segments WHERE item_type = 'audio' AND item_id = $1`, id)
		_, _ = db.ExecContext(context.Background(), `DELETE FROM audio_transcriptions WHERE id = $1`, id)
	})
	return id
}

func TestCompleteAudioTranscriptionQueuesFormattingInPostgres(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	id := insertTestAudio(t, db, "processing")
	startMS := int64(0)
	endMS := int64(1500)
	audio := &models.AudioTranscription{
		ID:                 id,
		Duration:           1.5,
		Language:           "en",
		TranscriptText:     "This is a test.",
		WordCount:          4,
		Status:             "completed",
		ProcessingStage:    "completed",
		ProcessingProgress: 100,
		OmittedRanges:      json.RawMessage(`[]`),
		FormattingStatus:   "pending",
	}
	segments := []models.MediaSegment{{StartMS: &startMS, EndMS: &endMS, Text: "This is a test."}}

	updated, err := db.CompleteAudioTranscriptionWithSegments(ctx, audio, segments)
	if err != nil {
		t.Fatalf("complete audio transcription: %v", err)
	}
	if !updated {
		t.Fatal("expected active audio transcription to be completed")
	}

	var status, transcript, formattingStatus, payloadAudioID string
	err = db.QueryRowContext(ctx, `
		SELECT a.status, a.transcript_text, a.formatting_status,
		       j.payload->>'audio_id'
		FROM audio_transcriptions a
		JOIN background_jobs j ON j.resource_id = a.id
		WHERE a.id = $1 AND j.job_type = 'audio_transcript_formatting'`, id).
		Scan(&status, &transcript, &formattingStatus, &payloadAudioID)
	if err != nil {
		t.Fatalf("read completed audio and formatting job: %v", err)
	}
	if status != "completed" || transcript != audio.TranscriptText || formattingStatus != "pending" {
		t.Fatalf("unexpected completed state: status=%q transcript=%q formatting=%q", status, transcript, formattingStatus)
	}
	if payloadAudioID != id {
		t.Fatalf("formatting payload audio_id = %q, want %q", payloadAudioID, id)
	}

	var segmentCount int
	if err := db.GetContext(ctx, &segmentCount, `SELECT COUNT(*) FROM media_segments WHERE item_type = 'audio' AND item_id = $1`, id); err != nil {
		t.Fatalf("count media segments: %v", err)
	}
	if segmentCount != 1 {
		t.Fatalf("media segment count = %d, want 1", segmentCount)
	}
}

func TestQueueAudioTranscriptFormattingInPostgres(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	id := insertTestAudio(t, db, "completed")
	if _, err := db.ExecContext(ctx, `UPDATE audio_transcriptions SET transcript_text = 'Ready.' WHERE id = $1`, id); err != nil {
		t.Fatalf("prepare completed audio: %v", err)
	}

	if err := db.QueueAudioTranscriptFormatting(ctx, id); err != nil {
		t.Fatalf("queue transcript formatting: %v", err)
	}

	var formattingStatus, payloadAudioID string
	err := db.QueryRowContext(ctx, `
		SELECT a.formatting_status, j.payload->>'audio_id'
		FROM audio_transcriptions a
		JOIN background_jobs j ON j.resource_id = a.id
		WHERE a.id = $1 AND j.job_type = 'audio_transcript_formatting'`, id).
		Scan(&formattingStatus, &payloadAudioID)
	if err != nil {
		t.Fatalf("read queued formatting job: %v", err)
	}
	if formattingStatus != "pending" || payloadAudioID != id {
		t.Fatalf("unexpected formatting job: status=%q audio_id=%q", formattingStatus, payloadAudioID)
	}
}

func TestFailAudioTranscriptionAfterProcessingErrorInPostgres(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	id := insertTestAudio(t, db, "processing")
	const message = "The original recording is safe. Please retry transcription."

	updated, err := db.FailAudioTranscriptionAfterProcessingError(ctx, id, message)
	if err != nil {
		t.Fatalf("mark terminal failure: %v", err)
	}
	if !updated {
		t.Fatal("expected active audio transcription to be marked failed")
	}

	var status, stage, errorMessage string
	var progress int
	if err := db.QueryRowContext(ctx, `
		SELECT status, processing_stage, processing_progress, error_message
		FROM audio_transcriptions WHERE id = $1`, id).
		Scan(&status, &stage, &progress, &errorMessage); err != nil {
		t.Fatalf("read failed audio transcription: %v", err)
	}
	if status != "failed" || stage != "failed" || progress != 100 || errorMessage != message {
		t.Fatalf("unexpected failure state: status=%q stage=%q progress=%d message=%q", status, stage, progress, errorMessage)
	}

	updated, err = db.FailAudioTranscriptionAfterProcessingError(ctx, id, message)
	if err != nil {
		t.Fatalf("repeat terminal failure update: %v", err)
	}
	if updated {
		t.Fatal("terminal audio transcription should not be updated twice")
	}
}
