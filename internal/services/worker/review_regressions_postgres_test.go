package worker

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/storage"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/summary"
	"github.com/google/uuid"
)

func TestReviewRecoveryPreservesBackfillAndCappedTitleRetry(t *testing.T) {
	db := backfillDB(t)
	ctx := context.Background()
	user, id := uuid.NewString(), uuid.NewString()
	if _, err := db.Exec(`INSERT INTO users(id,email,password_hash) VALUES($1,$2,'unused')`, user, user+"@example.invalid"); err != nil {
		t.Fatal(err)
	}
	defer db.Exec(`DELETE FROM users WHERE id=$1`, user)
	if _, err := db.Exec(`INSERT INTO audio_transcriptions(id,filename,original_name,status,user_id,transcript_text,summary_text,summary_status,content_type) VALUES($1,'test.m4a','New Recording 42','completed',$2,'Some source speech','Existing summary','completed','voice_memo')`, id, user); err != nil {
		t.Fatal(err)
	}
	defer db.Exec(`DELETE FROM audio_transcriptions WHERE id=$1`, id)
	defer db.Exec(`DELETE FROM background_jobs WHERE resource_id=$1`, id)
	if err := db.EnsureUsagePolicy(ctx, user, 300, 1, "", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ReserveAIRequest(ctx, user); err != nil {
		t.Fatal(err)
	}
	original := http.DefaultTransport
	calls := 0
	http.DefaultTransport = emailTestTransport(func(r *http.Request) (*http.Response, error) {
		calls++
		return nil, fmt.Errorf("provider must not be reached while capped")
	})
	defer func() { http.DefaultTransport = original }()
	pool := NewPool(3, 10, db, nil, summary.New("synthetic-key", "test/model"))
	defer pool.cancel()
	if _, err := pool.RunBackfill(ctx, "enrichment", user, false); err != nil {
		t.Fatal(err)
	}
	var job models.BackgroundJob
	if err := db.Get(&job, `SELECT * FROM background_jobs WHERE resource_id=$1`, id); err != nil {
		t.Fatal(err)
	}
	originalPayload := string(job.Payload)
	// Model a pre-deploy pending row, with its actual durable settings intact.
	if _, err := db.Exec(`UPDATE audio_transcriptions SET summary_status='pending' WHERE id=$1`, id); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`UPDATE background_jobs SET payload=$2::jsonb WHERE id=$1`, job.ID, originalPayload); err != nil {
		t.Fatal(err)
	}
	if created, err := pool.RecoverAudioSummaryJobs(ctx, 200); err != nil {
		t.Fatal(err)
	} else {
		t.Logf("recovery created missing jobs=%d", created)
	}
	if err := db.Get(&job, `SELECT * FROM background_jobs WHERE id=$1`, job.ID); err != nil {
		t.Fatal(err)
	}
	if string(job.Payload) != originalPayload || job.Priority != 10 {
		t.Fatalf("startup replaced backfill settings: %s priority=%d", job.Payload, job.Priority)
	}
	var payload AudioSummaryPayload
	if err := json.Unmarshal(job.Payload, &payload); err != nil {
		t.Fatal(err)
	}
	if !payload.Automatic || payload.TitleSource != "New Recording 42" || !payload.TitleOnly || payload.ContentType != "voice_memo" {
		t.Fatalf("lost settings %+v", payload)
	}
	if _, err := db.Exec(`UPDATE background_jobs SET status='running',locked_by=$2,lease_expires_at=NOW()+INTERVAL '1 minute',attempts=1 WHERE id=$1`, job.ID, pool.instanceID); err != nil {
		t.Fatal(err)
	}
	job.Attempts = 1
	job.MaxAttempts = 5
	pool.runClaimedJob(0, &job)
	var status string
	if err := db.Get(&status, `SELECT status FROM background_jobs WHERE id=$1`, job.ID); err != nil || status != "failed" || calls != 0 {
		t.Fatalf("capped title incorrectly finished: %s %v", status, err)
	}
	dry, err := pool.RunBackfill(ctx, "enrichment", user, true)
	if err != nil || dry.Titles != 1 {
		t.Fatalf("capped title cannot retry: %+v %v", dry, err)
	}
	// Restoring quota lets the next explicit run complete the same title task.
	if _, err := db.Exec(`UPDATE account_monthly_usage SET ai_requests=0 WHERE user_id=$1`, user); err != nil {
		t.Fatal(err)
	}
	if result, err := pool.RunBackfill(ctx, "enrichment", user, false); err != nil || result.Enqueued != 1 {
		t.Fatalf("retry enqueue %+v %v", result, err)
	}
	if err := db.Get(&job, `SELECT * FROM background_jobs WHERE resource_id=$1 AND status='queued'`, id); err != nil {
		t.Fatal(err)
	}
	http.DefaultTransport = emailTestTransport(func(r *http.Request) (*http.Response, error) {
		calls++
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(`{"model":"test/model","choices":[{"message":{"content":"A descriptive title"},"finish_reason":"stop"}]}`))}, nil
	})
	if err := pool.processAudioSummary(Job{ID: id, QueueID: job.ID, Payload: job.Payload}); err != nil {
		t.Fatal(err)
	}
	at, err := db.GetAudioTranscription(ctx, id)
	if err != nil || at.OriginalName != "A descriptive title" || calls != 1 {
		t.Fatalf("title retry %+v calls=%d err=%v", at, calls, err)
	}
}

func TestReviewDisabledTitleOnlyDoesNotRemainPending(t *testing.T) {
	db := backfillDB(t)
	user, id := uuid.NewString(), uuid.NewString()
	if _, err := db.Exec(`INSERT INTO users(id,email,password_hash) VALUES($1,$2,'unused')`, user, user+"@example.invalid"); err != nil {
		t.Fatal(err)
	}
	defer db.Exec(`DELETE FROM users WHERE id=$1`, user)
	if _, err := db.Exec(`INSERT INTO processing_preferences(user_id,automatic_summaries) VALUES($1,false)`, user); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO audio_transcriptions(id,filename,original_name,status,user_id,transcript_text,summary_status) VALUES($1,'test','Chosen name','completed',$2,'Some speech','pending')`, id, user); err != nil {
		t.Fatal(err)
	}
	defer db.Exec(`DELETE FROM audio_transcriptions WHERE id=$1`, id)
	defer db.Exec(`DELETE FROM background_jobs WHERE resource_id=$1`, id)
	pool := NewPool(1, 10, db, nil, &summary.Service{})
	defer pool.cancel()
	payload, err := json.Marshal(AudioSummaryPayload{AudioID: id, Automatic: true, TitleOnly: true})
	if err != nil {
		t.Fatal(err)
	}
	if err := pool.processAudioSummary(Job{ID: id, Payload: payload}); err != nil {
		t.Fatal(err)
	}
	var status string
	if err := db.Get(&status, `SELECT summary_status FROM audio_transcriptions WHERE id=$1`, id); err != nil || status != "skipped" {
		t.Fatalf("disabled title-only status=%s %v", status, err)
	}
}

func TestReviewDispatcherStartAndDownloadErrorsRetainRetryCause(t *testing.T) {
	db := backfillDB(t)
	pool := NewPool(1, 10, db, nil, nil)
	defer pool.cancel()
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	err := pool.processBackfill(Job{ID: uuid.NewString()})
	var retry *retryableJobError
	if !errors.As(err, &retry) {
		t.Fatalf("dispatch start failure not retryable: %v", err)
	}
	// Separate connection: a storage error must survive wrapping for diagnosis.
	db = backfillDB(t)
	id := uuid.NewString()
	if _, err := db.Exec(`INSERT INTO audio_transcriptions(id,filename,original_name,status,audio_s3_status,audio_s3_key) VALUES($1,'source','Source','completed','uploaded','test/source')`, id); err != nil {
		t.Fatal(err)
	}
	defer db.Exec(`DELETE FROM audio_transcriptions WHERE id=$1`, id)
	cause := fmt.Errorf("synthetic storage outage")
	original := http.DefaultTransport
	http.DefaultTransport = emailTestTransport(func(r *http.Request) (*http.Response, error) { return nil, cause })
	defer func() { http.DefaultTransport = original }()
	pool2 := NewPool(1, 10, db, nil, nil)
	defer pool2.cancel()
	pool2.SetAudioStorage(storage.NewS3("synthetic", "synthetic", "", "test-region", "test-bucket", "", 1))
	if err := pool2.processAudioWaveform(Job{ID: id}); !errors.Is(err, cause) {
		t.Fatalf("lost download cause: %v", err)
	}
}
