package database

import (
	"context"
	"database/sql"
	"errors"
	"math"
	"time"

	"github.com/jackc/pgx/v5/pgconn"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

var ErrMonthlyUsageCap = errors.New("monthly usage cap reached")

func IsUsageCap(err error) bool {
	var pg *pgconn.PgError
	return errors.Is(err, ErrMonthlyUsageCap) || (errors.As(err, &pg) && pg.Code == "P0402")
}

type Usage struct {
	Month                     time.Time `json:"month" db:"month"`
	TranscriptionSeconds      int64     `json:"transcription_seconds" db:"transcription_seconds"`
	TranscriptionLimitSeconds int64     `json:"transcription_limit_seconds" db:"transcription_limit_seconds"`
	AIRequests                int64     `json:"ai_requests" db:"ai_requests"`
	AIRequestLimit            int64     `json:"ai_request_limit" db:"ai_request_limit"`
	Exempt                    bool      `json:"exempt" db:"exempt"`
}

// Policy defaults are captured on first use, so a future per-account override
// is not overwritten by every request. Exemption is derived from explicit
// owner configuration, never an email, client flag, or first-created account.
func (db *DB) EnsureUsagePolicy(ctx context.Context, userID string, minutes, ai int, ownerID, ownerKeyID, ownerPrefix string) error {
	if minutes <= 0 {
		minutes = 300
	}
	if ai <= 0 {
		ai = 1000
	}
	_, err := db.ExecContext(ctx, `INSERT INTO account_usage_policies(user_id,transcription_limit_seconds,ai_request_limit,exempt)
 VALUES($1,$2,$3, COALESCE($1::text=NULLIF($4,''),FALSE) OR EXISTS(SELECT 1 FROM api_keys WHERE user_id=$1 AND (id::text=NULLIF($5,'') OR key_prefix=NULLIF($6,''))))
 ON CONFLICT(user_id) DO UPDATE SET exempt=EXCLUDED.exempt`, userID, int64(minutes)*60, ai, ownerID, ownerKeyID, ownerPrefix)
	return err
}
func (db *DB) AccountUsage(ctx context.Context, userID string) (*Usage, error) {
	var usage Usage
	err := db.GetContext(ctx, &usage, `SELECT date_trunc('month',NOW() AT TIME ZONE 'UTC')::date AS month,p.transcription_limit_seconds,p.ai_request_limit,p.exempt,COALESCE(u.transcription_seconds,0) AS transcription_seconds,COALESCE(u.ai_requests,0) AS ai_requests FROM account_usage_policies p LEFT JOIN account_monthly_usage u ON u.user_id=p.user_id AND u.month=date_trunc('month',NOW() AT TIME ZONE 'UTC')::date WHERE p.user_id=$1`, userID)
	return &usage, err
}
func (db *DB) ReserveAIRequest(ctx context.Context, userID string) error {
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var exempt bool
	var limit int64
	if err = tx.QueryRowContext(ctx, `SELECT exempt,ai_request_limit FROM account_usage_policies WHERE user_id=$1 FOR UPDATE`, userID).Scan(&exempt, &limit); err != nil {
		return err
	}
	if exempt {
		return nil
	}
	var count int64
	err = tx.QueryRowContext(ctx, `INSERT INTO account_monthly_usage(user_id,month,ai_requests) VALUES($1,date_trunc('month',NOW() AT TIME ZONE 'UTC')::date,1) ON CONFLICT(user_id,month) DO UPDATE SET ai_requests=account_monthly_usage.ai_requests+1 WHERE account_monthly_usage.ai_requests<$2 RETURNING ai_requests`, userID, limit).Scan(&count)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrMonthlyUsageCap
	}
	if err != nil {
		return err
	}
	return tx.Commit()
}
func (db *DB) RefundAIRequest(ctx context.Context, userID string, month time.Time) error {
	_, err := db.ExecContext(ctx, `UPDATE account_monthly_usage SET ai_requests=GREATEST(ai_requests-1,0) WHERE user_id=$1 AND month=$2`, userID, month)
	return err
}

// ReserveTranscriptionDuration must precede paid transcription. Unknown or
// invalid duration fails closed for capped accounts; owner/legacy work keeps
// its existing recovery path. Each resource is charged once per UTC month.
func (db *DB) ReserveTranscriptionDuration(ctx context.Context, userID *string, apiKeyID *string, resourceID string, seconds float64) error {
	var account string
	if userID != nil {
		account = *userID
	} else if apiKeyID != nil {
		if err := db.GetContext(ctx, &account, `SELECT COALESCE(user_id::text,'') FROM api_keys WHERE id=$1`, *apiKeyID); err != nil {
			return err
		}
	}
	if account == "" {
		return nil
	}
	var capped bool
	if err := db.GetContext(ctx, &capped, `SELECT EXISTS(SELECT 1 FROM account_usage_policies WHERE user_id=$1 AND NOT exempt)`, account); err != nil {
		return err
	}
	if !capped {
		return nil
	}
	if seconds <= 0 || math.IsNaN(seconds) || math.IsInf(seconds, 0) {
		return ErrMonthlyUsageCap
	}
	_, err := db.ExecContext(ctx, `SELECT reserve_transcription_usage($1,$2,$3,FALSE)`, account, resourceID, int64(math.Ceil(seconds)))
	return err
}

// CreateBatchWithTranscripts makes the whole admission atomic. A quota failure
// on the last URL rolls back every earlier resource and its trigger-created
// outbox job instead of leaving invisible work after a rejected request.
func (db *DB) CreateBatchWithTranscripts(ctx context.Context, b *models.Batch, transcripts []models.Transcript) error {
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err = tx.QueryRowContext(ctx, `INSERT INTO batches(status,total_count,completed_count,failed_count,user_id,api_key_id) VALUES($1,$2,$3,$4,$5,$6) RETURNING id,created_at,updated_at`, b.Status, b.TotalCount, b.CompletedCount, b.FailedCount, b.UserID, b.APIKeyID).Scan(&b.ID, &b.CreatedAt, &b.UpdatedAt); err != nil {
		return err
	}
	for i := range transcripts {
		t := &transcripts[i]
		t.BatchID = &b.ID
		if err = tx.QueryRowContext(ctx, `INSERT INTO transcripts(youtube_url,youtube_id,title,channel_name,duration,language,transcript_text,word_count,status,error_message,batch_id,user_id,api_key_id) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) RETURNING id,created_at,updated_at`, t.YouTubeURL, t.YouTubeID, t.Title, t.ChannelName, t.Duration, t.Language, t.TranscriptText, t.WordCount, t.Status, t.ErrorMessage, t.BatchID, t.UserID, t.APIKeyID).Scan(&t.ID, &t.CreatedAt, &t.UpdatedAt); err != nil {
			return err
		}
	}
	return tx.Commit()
}
