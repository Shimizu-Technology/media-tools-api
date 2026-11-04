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
	if err := db.EnsureUsagePolicy(ctx, userID, 2, 3, "", "", ""); err != nil {
		t.Fatal(err)
	}
	var passed atomic.Int32
	var wg sync.WaitGroup
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			err := db.ReserveAIRequest(ctx, userID)
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
	if err := db.EnsureUsagePolicy(ctx, userID, 2, 3, userID, "", ""); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 5; i++ {
		if err := db.ReserveAIRequest(ctx, userID); err != nil {
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
	if err := db.EnsureUsagePolicy(ctx, userID, 1, 2, "", "", ""); err != nil {
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
	if err := db.EnsureUsagePolicy(ctx, userID, 300, 2, "", "", ""); err != nil {
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
	if err := db.ReserveAIRequest(ctx, userID); !IsUsageCap(err) {
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
