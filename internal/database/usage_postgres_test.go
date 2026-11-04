package database

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	"github.com/google/uuid"
)

func TestUsageAtomicConcurrentCapsMonthAndOwner(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := createPasswordTestUser(t, db)
	if err := db.EnsureUsagePolicy(ctx, userID, 2, 3, "", ""); err != nil {
		t.Fatal(err)
	}
	var passed atomic.Int32
	var wg sync.WaitGroup
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := db.ReserveAIRequest(ctx, userID)
			if err == nil {
				passed.Add(1)
			} else if !IsUsageCap(err) {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if passed.Load() != 3 {
		t.Fatalf("AI cap race admitted %d want 3", passed.Load())
	}
	first, second := uuid.NewString(), uuid.NewString()
	if err := db.ReserveTranscriptionDuration(ctx, &userID, nil, first, 80); err != nil {
		t.Fatal(err)
	}
	if err := db.ReserveTranscriptionDuration(ctx, &userID, nil, first, 80); err != nil {
		t.Fatal("retry was double charged")
	}
	if err := db.ReserveTranscriptionDuration(ctx, &userID, nil, second, 41); !IsUsageCap(err) {
		t.Fatal("duration cap not enforced")
	}
	if err := db.ReserveTranscriptionDuration(ctx, &userID, nil, second, 0); !IsUsageCap(err) {
		t.Fatal("unknown duration admitted for capped account")
	}
	usage, err := db.AccountUsage(ctx, userID)
	if err != nil || usage.TranscriptionSeconds != 80 || usage.AIRequests != 3 {
		t.Fatal("usage ledger mismatch")
	}
	if _, err := db.ExecContext(ctx, `UPDATE account_monthly_usage SET month=month-INTERVAL '1 month' WHERE user_id=$1`, userID); err != nil {
		t.Fatal(err)
	}
	usage, err = db.AccountUsage(ctx, userID)
	if err != nil || usage.TranscriptionSeconds != 0 || usage.AIRequests != 0 {
		t.Fatal("calendar month did not reset")
	}
	if err := db.EnsureUsagePolicy(ctx, userID, 2, 3, userID, ""); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 5; i++ {
		if _, err := db.ReserveAIRequest(ctx, userID); err != nil {
			t.Fatal("owner capped")
		}
	}
	if err := db.ReserveTranscriptionDuration(ctx, &userID, nil, second, 100000); err != nil {
		t.Fatal("owner duration capped")
	}
}
func TestUsageAdmissionBatchRollbackAndFailedProvisionalRefund(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := createPasswordTestUser(t, db)
	if err := db.EnsureUsagePolicy(ctx, userID, 1, 2, "", ""); err != nil {
		t.Fatal(err)
	}
	batch := &models.Batch{Status: models.StatusPending, TotalCount: 2, UserID: &userID}
	transcripts := []models.Transcript{{YouTubeURL: "https://example.invalid/1", YouTubeID: uuid.NewString(), Status: models.StatusPending, UserID: &userID}, {YouTubeURL: "https://example.invalid/2", YouTubeID: uuid.NewString(), Status: models.StatusPending, UserID: &userID}}
	if err := db.CreateBatchWithTranscripts(ctx, batch, transcripts); !IsUsageCap(err) {
		t.Fatal("batch should exceed cap atomically", err)
	}
	var count int
	if err := db.GetContext(ctx, &count, `SELECT COUNT(*) FROM transcripts WHERE user_id=$1`, userID); err != nil || count != 0 {
		t.Fatal("rejected batch left accepted resources")
	}
	if err := db.GetContext(ctx, &count, `SELECT COUNT(*) FROM batches WHERE user_id=$1`, userID); err != nil || count != 0 {
		t.Fatal("rejected batch left orphan batch")
	}
	audio := &models.AudioTranscription{Filename: "usage.m4a", OriginalName: "usage.m4a", Status: "pending", UserID: &userID}
	if err := db.CreateAudioTranscription(ctx, audio); err != nil {
		t.Fatal(err)
	}
	usage, _ := db.AccountUsage(ctx, userID)
	if usage.TranscriptionSeconds != 60 {
		t.Fatal("no admission reservation")
	}
	audio.OmittedRanges = []byte(`[]`)
	audio.SummaryEvidence = []byte(`{}`)
	audio.Status = "failed"
	if err := db.UpdateAudioTranscription(ctx, audio); err != nil {
		t.Fatal(err)
	}
	usage, _ = db.AccountUsage(ctx, userID)
	if usage.TranscriptionSeconds != 0 {
		t.Fatal("provisional failure not refunded")
	}
}

func TestAutomaticAIReservationsShareCapAndRecoverWithoutDoubleCharge(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := createPasswordTestUser(t, db)
	if err := db.EnsureUsagePolicy(ctx, userID, 300, 2, "", ""); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if err := db.ReserveAutomaticAIRequest(ctx, &userID, nil, "durable-job:title"); err != nil {
			t.Fatal(err)
		}
	}
	if err := db.ReserveAutomaticAIRequest(ctx, &userID, nil, "durable-job:summary"); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ReserveAIRequest(ctx, userID); !IsUsageCap(err) {
		t.Fatal("automatic requests did not share the interactive cap")
	}
	if err := db.ReserveAutomaticAIRequest(ctx, &userID, nil, "another-job:summary"); !IsUsageCap(err) {
		t.Fatal("automatic producer bypassed cap")
	}
	usage, err := db.AccountUsage(ctx, userID)
	if err != nil || usage.AIRequests != 2 {
		t.Fatal("retry double charged automatic work")
	}
}

func TestRecoveredPolicyAndPreviousMonthRefund(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	user := createPasswordTestUser(t, db)
	resource := uuid.NewString()
	if err := db.ReserveTranscriptionDuration(ctx, &user, nil, resource, 0); !IsUsageCap(err) {
		t.Fatalf("missing policy must fail closed: %v", err)
	}
	if err := db.EnsureUsagePolicy(ctx, user, 300, 1000, user, ""); err != nil {
		t.Fatal(err)
	}
	if err := db.ReserveTranscriptionDuration(ctx, &user, nil, resource, 0); err != nil {
		t.Fatalf("owner exemption changed: %v", err)
	}
	if err := db.EnsureUsagePolicy(ctx, user, 300, 1000, "", ""); err != nil {
		t.Fatal(err)
	}
	item := &models.AudioTranscription{Filename: "refund.m4a", OriginalName: "refund", Status: "pending", UserID: &user}
	if err := db.CreateAudioTranscription(ctx, item); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `UPDATE account_transcription_usage SET month=(date_trunc('month',NOW() AT TIME ZONE 'UTC')-interval '1 month')::date WHERE resource_id=$1;`, item.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `UPDATE account_monthly_usage SET month=(date_trunc('month',NOW() AT TIME ZONE 'UTC')-interval '1 month')::date WHERE user_id=$1`, user); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `UPDATE audio_transcriptions SET status='failed' WHERE id=$1`, item.ID); err != nil {
		t.Fatal(err)
	}
	var used int64
	if err := db.GetContext(ctx, &used, `SELECT transcription_seconds FROM account_monthly_usage WHERE user_id=$1`, user); err != nil || used != 0 {
		t.Fatalf("old month refund: %d %v", used, err)
	}
	if _, err := db.ExecContext(ctx, `UPDATE account_usage_policies SET transcription_limit_seconds=1 WHERE user_id=$1`, user); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `UPDATE audio_transcriptions SET status='pending' WHERE id=$1`, item.ID); !IsUsageCap(err) {
		t.Fatalf("retry admission must enforce cap: %v", err)
	}
}

func TestRetryKeepsTheChargedTranscriptionDuration(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := createPasswordTestUser(t, db)
	if err := db.EnsureUsagePolicy(ctx, userID, 300, 1000, "", ""); err != nil {
		t.Fatal(err)
	}
	var audioID string
	if err := db.QueryRowContext(ctx, `
		INSERT INTO audio_transcriptions (user_id, filename, original_name, status)
		VALUES ($1, 'a.caf', 'a.caf', 'pending') RETURNING id`, userID).Scan(&audioID); err != nil {
		t.Fatal(err)
	}
	if err := db.ReserveTranscriptionDuration(ctx, &userID, nil, audioID, 3600); err != nil {
		t.Fatal(err)
	}
	seconds := func() int64 {
		t.Helper()
		var total int64
		if err := db.GetContext(ctx, &total, `SELECT COALESCE(SUM(transcription_seconds),0) FROM account_monthly_usage WHERE user_id = $1`, userID); err != nil {
			t.Fatal(err)
		}
		return total
	}
	if got := seconds(); got != 3600 {
		t.Fatalf("charged = %d", got)
	}
	for _, status := range []string{"failed", "pending", "failed"} {
		if _, err := db.ExecContext(ctx, `UPDATE audio_transcriptions SET status = $2 WHERE id = $1`, audioID, status); err != nil {
			t.Fatal(err)
		}
		if got := seconds(); got != 3600 {
			t.Fatalf("after %s the charge moved to %d", status, got)
		}
	}
}
