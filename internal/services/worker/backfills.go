package worker

import (
	"context"
	"fmt"
	"time"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
)

// RunBackfill reuses AudioSummaryPayload/Automatic and the normal worker path.
// Dry runs perform only SELECTs, including no job, usage or state writes.
func (p *Pool) RunBackfill(ctx context.Context, kind, userID string, dryRun bool, runIDs ...string) (database.BackfillResult, error) {
	result := database.BackfillResult{Kind: kind, DryRun: dryRun}
	candidates, err := p.db.ListBackfillCandidates(ctx, kind, userID)
	if err != nil {
		return result, err
	}
	for _, candidate := range candidates {
		title := ""
		if kind == "enrichment" && candidate.Manual && isGeneratedRecordingName(candidate.Name) {
			result.ProtectedTitles++
		}
		summary := candidate.NeedsSummary && candidate.AutomaticSummaries
		if kind == "enrichment" && !candidate.Manual && !candidate.FinishedTitle && isGeneratedRecordingName(candidate.Name) {
			title = candidate.Name
		}
		if kind == "enrichment" && !summary && title == "" {
			continue
		}
		result.Eligible++
		if summary {
			result.Summaries++
		}
		if title != "" {
			result.Titles++
		}
		if dryRun {
			continue
		}
		queued, err := p.db.QueueBackfillCandidate(ctx, kind, userID, candidate, title, summary, runIDs...)
		if err != nil {
			p.Wake()
			return result, err
		}
		if queued {
			result.Enqueued++
		}
	}
	if !dryRun {
		p.Wake()
	}
	return result, nil
}

func (p *Pool) processBackfill(job Job) error {
	var kind, user string
	if err := p.db.QueryRowContext(p.ctx, `UPDATE backfill_runs SET dispatch_status='running' WHERE id=$1 RETURNING kind,COALESCE(user_id::text,'')`, job.ID).Scan(&kind, &user); err != nil {
		return err
	}
	if kind == "enrichment" && user == "" {
		return fmt.Errorf("backfill account no longer exists")
	}
	if _, err := p.RunBackfill(p.ctx, kind, user, false, job.ID); err != nil {
		return &retryableJobError{err: err, delay: 5 * time.Second}
	}
	_, err := p.db.ExecContext(p.ctx, `UPDATE backfill_runs SET dispatch_status='completed' WHERE id=$1`, job.ID)
	return err
}
