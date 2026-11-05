package database

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
)

// Migration 055 ran on 2026-11-04 UTC and flagged every existing recording. Rows
// newer than this only carry the flag because a person renamed them.
const legacyTitleFlagCutoff = "2026-11-05T00:00:00Z"

type BackfillCandidate struct {
	ID                 string `db:"id"`
	ContentType        string `db:"content_type"`
	Name               string `db:"original_name"`
	Manual             bool   `db:"title_manually_set"`
	NeedsSummary       bool   `db:"needs_summary"`
	FinishedTitle      bool   `db:"finished_title"`
	AutomaticSummaries bool   `db:"automatic_summaries"`
	// LegacyFlag means migration 055 may have set title_manually_set, rather than a
	// person. Set this only after checking the name's format.
	LegacyFlag bool `db:"legacy_flag"`
}

type BackfillResult struct {
	Kind            string   `json:"kind"`
	ID              string   `json:"id,omitempty"`
	DryRun          bool     `json:"dry_run"`
	Eligible        int      `json:"eligible"`
	Summaries       int      `json:"summaries"`
	TitleNames      []string `json:"title_names"`
	Titles          int      `json:"titles"`
	ProtectedTitles int      `json:"protected_titles"`
	Enqueued        int      `json:"enqueued"`
}

// ListBackfillCandidates reads bounded metadata, never the stored transcript.
// Selecting terminal waveform failures again would defeat its attempt budget.
func (db *DB) ListBackfillCandidates(ctx context.Context, kind, userID string) ([]BackfillCandidate, error) {
	var query string
	var args []any
	switch kind {
	case "waveforms":
		query = `SELECT a.id,a.original_name,a.content_type,a.title_manually_set,false AS needs_summary,true AS automatic_summaries,false AS finished_title,false AS legacy_flag
 FROM audio_transcriptions a WHERE a.status='completed' AND a.audio_s3_status='uploaded' AND a.audio_s3_key<>''
 AND a.waveform IS NULL AND a.waveform_status IN ('','pending') AND NOT EXISTS
 (SELECT 1 FROM background_jobs j WHERE j.resource_id=a.id AND j.job_type='audio_waveform' AND j.status IN ('queued','running')) ORDER BY a.created_at,a.id`
	case "enrichment":
		query = `SELECT a.id,a.original_name,a.content_type,a.title_manually_set,
 (btrim(a.summary_text)='' AND a.summary_status NOT IN ('pending','processing')) AS needs_summary,
 COALESCE(p.automatic_summaries,true) AS automatic_summaries,
 (a.created_at < '` + legacyTitleFlagCutoff + `'::timestamptz) AS legacy_flag,
 EXISTS(SELECT 1 FROM background_jobs j WHERE j.resource_id=a.id AND j.job_type='audio_summary' AND j.status='completed' AND j.payload->>'backfill'='true' AND j.payload->>'title_only'='true') AS finished_title
 FROM audio_transcriptions a LEFT JOIN processing_preferences p ON p.user_id=$1::uuid
 WHERE a.user_id=$1::uuid AND a.status='completed' AND btrim(a.transcript_text)<>''
 AND NOT EXISTS(SELECT 1 FROM background_jobs j WHERE j.resource_id=a.id AND j.job_type='audio_summary' AND j.status IN ('queued','running'))
 ORDER BY a.created_at,a.id`
		args = []any{userID}
	default:
		return nil, fmt.Errorf("invalid backfill kind")
	}
	var rows []BackfillCandidate
	if err := db.SelectContext(ctx, &rows, query, args...); err != nil {
		return nil, err
	}
	return rows, nil
}

// QueueBackfillCandidate rechecks under a row lock. The active-job unique index
// and historical backfill key make concurrent requests/resumption idempotent.
func (db *DB) QueueBackfillCandidate(ctx context.Context, kind, userID string, c BackfillCandidate, titleSource string, needsSummary bool, runIDs ...string) (bool, error) {
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	var ok bool
	predicate := `status='completed' AND audio_s3_status='uploaded' AND audio_s3_key<>'' AND waveform IS NULL AND waveform_status IN ('','pending')`
	args := []any{c.ID}
	if kind == "enrichment" {
		predicate = `status='completed' AND btrim(transcript_text)<>'' AND a.user_id=$2::uuid`
		args = append(args, userID)
	}
	err = tx.QueryRowContext(ctx, `SELECT true FROM audio_transcriptions a WHERE id=$1 AND `+predicate+` FOR UPDATE`, args...).Scan(&ok)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	jobType := "audio_waveform"
	payload := map[string]any{"backfill": true}
	if kind == "enrichment" {
		jobType = "audio_summary"
		// Re-evaluate summary presence and preference after acquiring the row lock.
		var missing, enabled bool
		var contentType string
		if err := tx.QueryRowContext(ctx, `SELECT content_type,btrim(summary_text)='',COALESCE((SELECT automatic_summaries FROM processing_preferences WHERE user_id=$2::uuid),true) FROM audio_transcriptions WHERE id=$1`, c.ID, userID).Scan(&contentType, &missing, &enabled); err != nil {
			return false, err
		}
		needsSummary = needsSummary && missing && enabled
		if titleSource != "" {
			var valid bool
			if err := tx.GetContext(ctx, &valid, `SELECT original_name=$2::text AND (NOT title_manually_set OR ($3::bool AND created_at < '`+legacyTitleFlagCutoff+`'::timestamptz)) FROM audio_transcriptions WHERE id=$1`, c.ID, titleSource, c.LegacyFlag); err != nil {
				return false, err
			}
			if !valid {
				titleSource = ""
			} else if c.LegacyFlag {
				// The worker's rename requires an unflagged row, and still compares
				// the name, so a rename during the provider call keeps winning.
				if _, err := tx.ExecContext(ctx, `UPDATE audio_transcriptions SET title_manually_set=false WHERE id=$1 AND original_name=$2::text`, c.ID, titleSource); err != nil {
					return false, err
				}
			}
		}
		if !needsSummary && titleSource == "" {
			return false, nil
		}
		payload = map[string]any{"backfill": true, "automatic": true, "audio_id": c.ID, "title_source": titleSource, "title_only": !needsSummary, "length": "medium", "content_type": contentType}
	}
	// One logical operation per item/backfill kind. Failed or quota-skipped AI
	// work can be explicitly resumed; completed work isn't charged again.
	var exists bool
	if err := tx.GetContext(ctx, &exists, `SELECT EXISTS(SELECT 1 FROM background_jobs WHERE resource_id=$1 AND job_type=$2::text AND (status IN ('queued','running') OR ($3::text='true' AND payload->>'backfill'='true' AND status='completed' AND payload->>'title_only'='true')))`, c.ID, jobType, fmt.Sprint(!needsSummary)); err != nil {
		return false, err
	}
	if exists {
		return false, nil
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return false, err
	}
	// Claim creation of a NEW job before changing resource state. If recovery
	// or a foreground request won the unique index race, this run owns no job.
	var jobID string
	err = tx.QueryRowContext(ctx, `INSERT INTO background_jobs(job_type,resource_id,payload,priority,max_attempts)
 VALUES($1::text,$2::uuid,$3::jsonb,10,$4::int)
 ON CONFLICT(job_type,resource_id) WHERE status IN ('queued','running') DO NOTHING RETURNING id`, jobType, c.ID, string(encoded), backfillMaxAttempts(kind)).Scan(&jobID)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if kind == "waveforms" {
		_, err = tx.ExecContext(ctx, `UPDATE audio_transcriptions SET waveform_status='pending' WHERE id=$1`, c.ID)
	}
	if err != nil {
		return false, err
	}
	if len(runIDs) > 0 && runIDs[0] != "" {
		if _, err = tx.ExecContext(ctx, `INSERT INTO backfill_run_jobs(run_id,job_id) VALUES($1::uuid,$2::uuid)`, runIDs[0], jobID); err != nil {
			return false, err
		}
	}

	return true, tx.Commit()
}

// CreateBackfillRun persists the dispatcher before returning its id. No scanning
// or provider work holds up the HTTP response, and a restart resumes dispatch.
func (db *DB) CreateBackfillRun(ctx context.Context, kind, userID string) (string, error) {
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	var id string
	if err = tx.QueryRowContext(ctx, `INSERT INTO backfill_runs(kind,user_id) VALUES($1::text,NULLIF($2::text,'')::uuid) RETURNING id`, kind, userID).Scan(&id); err != nil {
		return "", err
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO background_jobs(job_type,resource_id,priority) VALUES('admin_backfill',$1,10)`, id); err != nil {
		return "", err
	}
	return id, tx.Commit()
}

type BackfillProgress struct {
	ID             string `json:"id" db:"id"`
	Kind           string `json:"kind" db:"kind"`
	DispatchStatus string `json:"dispatch_status" db:"dispatch_status"`
	Queued         int    `json:"queued" db:"queued"`
	Running        int    `json:"running" db:"running"`
	Completed      int    `json:"completed" db:"completed"`
	Failed         int    `json:"failed" db:"failed"`
}

func (db *DB) GetBackfillProgress(ctx context.Context, id string) (BackfillProgress, error) {
	var progress BackfillProgress
	err := db.GetContext(ctx, &progress, `SELECT r.id,r.kind,r.dispatch_status,
 count(j.id) FILTER(WHERE j.status='queued') AS queued,
 count(j.id) FILTER(WHERE j.status='running') AS running,
 count(j.id) FILTER(WHERE j.status='completed') AS completed,
 count(j.id) FILTER(WHERE j.status='failed') AS failed
 FROM backfill_runs r LEFT JOIN backfill_run_jobs b ON b.run_id=r.id LEFT JOIN background_jobs j ON j.id=b.job_id
 WHERE r.id=$1 GROUP BY r.id`, id)
	return progress, err
}

func backfillMaxAttempts(kind string) int {
	if kind == "waveforms" {
		return 3
	}
	return 5
}
