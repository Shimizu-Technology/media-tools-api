package database

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

type reportableAIContent struct {
	SubjectType string          `db:"subject_type"`
	SubjectID   string          `db:"subject_id"`
	Snapshot    json.RawMessage `db:"content_snapshot"`
}

// CreateAIContentReport verifies that the selected output belongs to the
// current actor and stores one durable report per actor and output.
func (db *DB) CreateAIContentReport(
	ctx context.Context,
	report *models.AIContentReport,
) (bool, error) {
	content, err := db.getReportableAIContent(
		ctx,
		report.TargetType,
		report.TargetID,
		report.UserID,
		report.APIKeyID,
	)
	if err != nil {
		return false, err
	}
	report.SubjectType = content.SubjectType
	report.SubjectID = content.SubjectID
	report.ContentSnapshot = content.Snapshot

	err = db.QueryRowContext(ctx, `
		INSERT INTO ai_content_reports (
			target_type, target_id, subject_type, subject_id,
			user_id, api_key_id, category, details, content_snapshot
		)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
		ON CONFLICT DO NOTHING
		RETURNING id, status, admin_note, created_at, updated_at`,
		report.TargetType,
		report.TargetID,
		report.SubjectType,
		report.SubjectID,
		report.UserID,
		report.APIKeyID,
		report.Category,
		report.Details,
		report.ContentSnapshot,
	).Scan(
		&report.ID,
		&report.Status,
		&report.AdminNote,
		&report.CreatedAt,
		&report.UpdatedAt,
	)
	if err == nil {
		return true, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return false, fmt.Errorf("create AI content report: %w", err)
	}

	if err := db.getExistingAIContentReport(ctx, report); err != nil {
		return false, err
	}
	return false, nil
}

func (db *DB) getExistingAIContentReport(ctx context.Context, report *models.AIContentReport) error {
	var query string
	var ownerID string
	switch {
	case report.UserID != nil:
		query = `SELECT * FROM ai_content_reports
			WHERE target_type = $1 AND target_id = $2 AND user_id = $3`
		ownerID = *report.UserID
	case report.APIKeyID != nil:
		query = `SELECT * FROM ai_content_reports
			WHERE target_type = $1 AND target_id = $2 AND api_key_id = $3`
		ownerID = *report.APIKeyID
	default:
		return fmt.Errorf("AI content report owner is required")
	}
	if err := db.GetContext(ctx, report, query, report.TargetType, report.TargetID, ownerID); err != nil {
		return fmt.Errorf("load existing AI content report: %w", err)
	}
	return nil
}

func (db *DB) getReportableAIContent(
	ctx context.Context,
	targetType string,
	targetID string,
	userID *string,
	apiKeyID *string,
) (*reportableAIContent, error) {
	ownerColumn, ownerID, err := reportOwnerColumn(userID, apiKeyID)
	if err != nil {
		return nil, err
	}

	var query string
	switch targetType {
	case "chat_message":
		query = fmt.Sprintf(`
			SELECT s.item_type AS subject_type,
			       s.item_id AS subject_id,
			       jsonb_build_object(
			           'content', m.content,
			           'model_used', m.model_used,
			           'citations', m.citations
			       ) AS content_snapshot
			FROM transcript_chat_messages m
			JOIN transcript_chat_sessions s ON s.id = m.session_id
			WHERE m.id = $1 AND m.role = 'assistant' AND s.%s = $2`, ownerColumn)
	case "transcript_summary":
		query = fmt.Sprintf(`
			SELECT 'transcript' AS subject_type,
			       s.transcript_id AS subject_id,
			       jsonb_build_object(
			           'summary_text', s.summary_text,
			           'key_points', s.key_points,
			           'model_used', s.model_used
			       ) AS content_snapshot
			FROM summaries s
			JOIN transcripts t ON t.id = s.transcript_id
			WHERE s.id = $1
			  AND s.status = 'completed'
			  AND NULLIF(BTRIM(s.summary_text), '') IS NOT NULL
			  AND t.%s = $2`, ownerColumn)
	case "audio_summary":
		query = fmt.Sprintf(`
			SELECT 'audio' AS subject_type,
			       a.id AS subject_id,
			       jsonb_build_object(
			           'summary_text', a.summary_text,
			           'key_points', a.key_points,
			           'action_items', a.action_items,
			           'decisions', a.decisions,
			           'model_used', a.summary_model
			       ) AS content_snapshot
			FROM audio_transcriptions a
			WHERE a.id = $1
			  AND a.summary_status = 'completed'
			  AND NULLIF(BTRIM(a.summary_text), '') IS NOT NULL
			  AND a.%s = $2`, ownerColumn)
	default:
		return nil, fmt.Errorf("unsupported AI content target type")
	}

	var content reportableAIContent
	if err := db.GetContext(ctx, &content, query, targetID, ownerID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, sql.ErrNoRows
		}
		return nil, fmt.Errorf("load reportable AI content: %w", err)
	}
	return &content, nil
}

func reportOwnerColumn(userID, apiKeyID *string) (string, string, error) {
	if apiKeyID != nil {
		return "api_key_id", *apiKeyID, nil
	}
	if userID != nil {
		return "user_id", *userID, nil
	}
	return "", "", fmt.Errorf("AI content report owner is required")
}

// ListAIContentReports returns the moderation queue for an owner-authorized
// operations client. The selected output snapshot is included for review.
func (db *DB) ListAIContentReports(ctx context.Context, limit int) ([]models.AIContentReport, error) {
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	var reports []models.AIContentReport
	if err := db.SelectContext(ctx, &reports, `
		SELECT * FROM ai_content_reports
		ORDER BY
			CASE status WHEN 'open' THEN 0 WHEN 'reviewing' THEN 1 ELSE 2 END,
			created_at DESC
		LIMIT $1`, limit); err != nil {
		return nil, fmt.Errorf("list AI content reports: %w", err)
	}
	if reports == nil {
		reports = []models.AIContentReport{}
	}
	return reports, nil
}

// UpdateAIContentReport records the operator's moderation disposition.
func (db *DB) UpdateAIContentReport(
	ctx context.Context,
	id string,
	status string,
	adminNote string,
) (*models.AIContentReport, error) {
	var report models.AIContentReport
	if err := db.GetContext(ctx, &report, `
		UPDATE ai_content_reports
		SET status = $2, admin_note = $3
		WHERE id = $1
		RETURNING *`, id, status, adminNote); err != nil {
		return nil, fmt.Errorf("update AI content report: %w", err)
	}
	return &report, nil
}
