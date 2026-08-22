package database

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"testing"

	"github.com/google/uuid"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

func TestCreateAIContentReportScopesOutputAndDeduplicates(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()

	userID := insertAIReportUser(t, db)
	otherUserID := insertAIReportUser(t, db)
	transcriptID := insertAIReportTranscript(t, db, userID)

	var sessionID string
	if err := db.QueryRowContext(ctx, `
		INSERT INTO transcript_chat_sessions (item_type, item_id, transcript_id, user_id)
		VALUES ('transcript', $1, $1, $2) RETURNING id`, transcriptID, userID).Scan(&sessionID); err != nil {
		t.Fatalf("insert chat session: %v", err)
	}
	var messageID string
	if err := db.QueryRowContext(ctx, `
		INSERT INTO transcript_chat_messages (session_id, role, content, model_used, citations)
		VALUES ($1, 'assistant', 'Selected AI answer', 'test/model', '[]') RETURNING id`, sessionID).Scan(&messageID); err != nil {
		t.Fatalf("insert assistant message: %v", err)
	}

	report := &models.AIContentReport{
		TargetType: "chat_message",
		TargetID:   messageID,
		UserID:     &userID,
		Category:   "dangerous",
		Details:    "Unsafe instruction",
	}
	created, err := db.CreateAIContentReport(ctx, report)
	if err != nil || !created {
		t.Fatalf("CreateAIContentReport() = %t, %v", created, err)
	}
	if report.SubjectType != "transcript" || report.SubjectID != transcriptID {
		t.Fatalf("subject = %s:%s", report.SubjectType, report.SubjectID)
	}
	var snapshot map[string]any
	if err := json.Unmarshal(report.ContentSnapshot, &snapshot); err != nil {
		t.Fatalf("decode snapshot: %v", err)
	}
	if snapshot["content"] != "Selected AI answer" || snapshot["model_used"] != "test/model" {
		t.Fatalf("snapshot = %#v", snapshot)
	}

	duplicate := &models.AIContentReport{
		TargetType: "chat_message",
		TargetID:   messageID,
		UserID:     &userID,
		Category:   "other",
	}
	created, err = db.CreateAIContentReport(ctx, duplicate)
	if err != nil || created || duplicate.ID != report.ID {
		t.Fatalf("duplicate CreateAIContentReport() = %#v, %t, %v", duplicate, created, err)
	}

	unauthorized := &models.AIContentReport{
		TargetType: "chat_message",
		TargetID:   messageID,
		UserID:     &otherUserID,
		Category:   "other",
	}
	if _, err := db.CreateAIContentReport(ctx, unauthorized); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("other owner error = %v, want sql.ErrNoRows", err)
	}

	reports, err := db.ListAIContentReports(ctx, 10)
	if err != nil {
		t.Fatalf("ListAIContentReports() error = %v", err)
	}
	found := false
	for _, candidate := range reports {
		if candidate.ID == report.ID {
			found = true
		}
	}
	if !found {
		t.Fatalf("report %s missing from moderation queue", report.ID)
	}
	updated, err := db.UpdateAIContentReport(ctx, report.ID, "resolved", "Reviewed in test")
	if err != nil || updated.Status != "resolved" || updated.AdminNote != "Reviewed in test" {
		t.Fatalf("UpdateAIContentReport() = %#v, %v", updated, err)
	}
}

func TestCreateAIContentReportSupportsTranscriptAndAudioSummaries(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := insertAIReportUser(t, db)
	transcriptID := insertAIReportTranscript(t, db, userID)

	var summaryID string
	if err := db.QueryRowContext(ctx, `
		INSERT INTO summaries (
			transcript_id, model_used, prompt_used, summary_text,
			key_points, length, style, status
		) VALUES ($1, 'test/summary', 'prompt', 'Transcript summary', '["Point"]', 'medium', 'bullet', 'completed')
		RETURNING id`, transcriptID).Scan(&summaryID); err != nil {
		t.Fatalf("insert transcript summary: %v", err)
	}
	transcriptReport := &models.AIContentReport{
		TargetType: "transcript_summary",
		TargetID:   summaryID,
		UserID:     &userID,
		Category:   "deceptive",
	}
	if created, err := db.CreateAIContentReport(ctx, transcriptReport); err != nil || !created {
		t.Fatalf("create transcript summary report = %t, %v", created, err)
	}

	var audioID string
	if err := db.QueryRowContext(ctx, `
		INSERT INTO audio_transcriptions (
			filename, original_name, status, user_id, summary_text,
			key_points, action_items, decisions, summary_model, summary_status
		) VALUES (
			'audio.m4a', 'audio.m4a', 'completed', $1, 'Audio summary',
			'["Point"]', '["Action"]', '["Decision"]', 'test/audio', 'completed'
		) RETURNING id`, userID).Scan(&audioID); err != nil {
		t.Fatalf("insert audio summary: %v", err)
	}
	audioReport := &models.AIContentReport{
		TargetType: "audio_summary",
		TargetID:   audioID,
		UserID:     &userID,
		Category:   "privacy",
	}
	if created, err := db.CreateAIContentReport(ctx, audioReport); err != nil || !created {
		t.Fatalf("create audio summary report = %t, %v", created, err)
	}
}

func insertAIReportUser(t *testing.T, db *DB) string {
	t.Helper()
	var id string
	if err := db.QueryRowContext(context.Background(), `
		INSERT INTO users (email, password_hash, name)
		VALUES ($1, '', 'AI Report Test') RETURNING id`, uuid.NewString()+"@example.com").Scan(&id); err != nil {
		t.Fatalf("insert user: %v", err)
	}
	t.Cleanup(func() {
		if _, err := db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, id); err != nil {
			t.Errorf("delete AI report test user: %v", err)
		}
	})
	return id
}

func insertAIReportTranscript(t *testing.T, db *DB, userID string) string {
	t.Helper()
	var id string
	if err := db.QueryRowContext(context.Background(), `
		INSERT INTO transcripts (youtube_url, youtube_id, status, transcript_text, user_id)
		VALUES ('https://example.com/video', $1, 'completed', 'Source transcript', $2)
		RETURNING id`, uuid.NewString()[:12], userID).Scan(&id); err != nil {
		t.Fatalf("insert transcript: %v", err)
	}
	return id
}
