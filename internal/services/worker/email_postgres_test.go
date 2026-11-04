package worker

import (
	"context"
	"encoding/json"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/summary"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/transcriptformat"
	"io"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	emailservice "github.com/Shimizu-Technology/media-tools-api/internal/services/email"
	"github.com/google/uuid"
)

type emailTestTransport func(*http.Request) (*http.Response, error)

func (f emailTestTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestDurableAuthEmailRequeueAndDelivery(t *testing.T) {
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	db, err := database.New(url)
	if err != nil {
		t.Fatal("connect test database")
	}
	t.Cleanup(func() { _ = db.Close() })
	if err = db.RunMigrations("../../../migrations"); err != nil {
		t.Fatal(err)
	}
	service, _ := emailservice.New("resend", "synthetic-unit-key", "Media Tools <test@example.invalid>", "synthetic-worker-secret")
	id := uuid.NewString()
	address := uuid.NewString() + "@example.invalid"
	sealed, _ := service.Seal(emailservice.CodeMessage(address, "456789", "signup"))
	ch := database.EmailChallenge{ID: id, Purpose: "signup", Email: address, CodeHash: service.CodeHash(id, "456789"), PasswordHash: "synthetic-encoded-password-hash"}
	if _, err = db.IssueEmailChallenge(context.Background(), ch, sealed); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = db.Exec(`DELETE FROM background_jobs WHERE resource_id=$1`, id)
		_, _ = db.Exec(`DELETE FROM auth_email_challenges WHERE id=$1`, id)
	})
	pool := NewPool(1, 10, db, nil, nil)
	defer pool.cancel()
	pool.SetEmailService(service)
	calls := 0
	service.Client = &http.Client{Transport: emailTestTransport(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.Header.Get("Idempotency-Key") != "auth-email/"+id {
			t.Error("idempotency key changed")
		}
		status := 429
		if calls > 1 {
			status = 200
		}
		return &http.Response{StatusCode: status, Header: http.Header{"Retry-After": []string{"40"}}, Body: io.NopCloser(strings.NewReader("{}"))}, nil
	})}
	claim := func() *models.BackgroundJob {
		var job models.BackgroundJob
		err := db.Get(&job, `UPDATE background_jobs SET status='running',attempts=attempts+1,locked_by=$2,lease_expires_at=NOW()+INTERVAL '5 minutes' WHERE resource_id=$1 RETURNING *`, id, pool.instanceID)
		if err != nil {
			t.Fatal(err)
		}
		return &job
	}
	pool.runClaimedJob(1, claim())
	var status string
	var runAt time.Time
	if err = db.QueryRow(`SELECT status,run_at FROM background_jobs WHERE resource_id=$1`, id).Scan(&status, &runAt); err != nil || status != "queued" || time.Until(runAt) < 35*time.Second {
		t.Fatal("provider throttle not durably requeued")
	}
	// Simulate process replacement. It reads the same encrypted outbox and uses
	// the same provider key; no process-local secret or body needs recovery.
	pool2 := NewPool(1, 10, db, nil, nil)
	defer pool2.cancel()
	pool2.SetEmailService(service)
	pool.instanceID = pool2.instanceID
	pool2.runClaimedJob(1, claim())
	if err = db.Get(&status, `SELECT status FROM background_jobs WHERE resource_id=$1`, id); err != nil || status != "completed" || calls != 2 {
		t.Fatal("retry did not complete")
	}
	var stored string
	if err = db.Get(&stored, `SELECT sealed FROM auth_email_outbox WHERE id=$1`, id); err != nil || stored != "" {
		t.Fatal("delivered secret payload retained")
	}
}

func TestAutomaticEnrichmentChecksCapBeforeProvider(t *testing.T) {
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	db, err := database.New(url)
	if err != nil {
		t.Fatal("connect test database")
	}
	t.Cleanup(func() { _ = db.Close() })
	if err = db.RunMigrations("../../../migrations"); err != nil {
		t.Fatal(err)
	}
	var userID, audioID string
	if err = db.QueryRow(`INSERT INTO users(email,password_hash,name) VALUES($1,'','Automatic quota') RETURNING id`, uuid.NewString()+"@example.invalid").Scan(&userID); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.Exec(`DELETE FROM users WHERE id=$1`, userID) })
	if err = db.EnsureUsagePolicy(context.Background(), userID, 300, 1, "", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ReserveAIRequest(context.Background(), userID); err != nil {
		t.Fatal(err)
	}
	if err = db.QueryRow(`INSERT INTO audio_transcriptions(filename,original_name,status,transcript_text,summary_status,user_id) VALUES('quota.m4a','New Recording','completed','Synthetic quota fixture.','pending',$1) RETURNING id`, userID).Scan(&audioID); err != nil {
		t.Fatal(err)
	}
	// A nonnil but unconfigured service would reject a provider call. Receiving
	// the cap error instead proves both automatic paths stop at the quota gate.
	pool := NewPool(1, 10, db, nil, &summary.Service{})
	defer pool.cancel()
	for _, source := range []string{"New Recording", ""} {
		payload, _ := json.Marshal(AudioSummaryPayload{AudioID: audioID, Automatic: true, TitleSource: source})
		err = pool.processAudioSummary(Job{ID: audioID, QueueID: uuid.NewString(), Payload: payload})
		if err != nil {
			t.Fatal(err)
		}
		var status, message, transcriptStatus string
		if err = db.QueryRow(`SELECT summary_status,summary_error_message,status FROM audio_transcriptions WHERE id=$1`, audioID).Scan(&status, &message, &transcriptStatus); err != nil || status != "skipped" || !strings.Contains(message, "monthly AI limit") || transcriptStatus != "completed" {
			t.Fatal("automatic cap did not skip enrichment and preserve transcription", err)
		}
	}
}

func TestFormattingJobsChargeCapAndCannotRequeueWhenCapped(t *testing.T) {
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	db, err := database.New(url)
	if err != nil {
		t.Fatal("connect local database")
	}
	defer db.Close()
	if err = db.RunMigrations("../../../migrations"); err != nil {
		t.Fatal(err)
	}
	var userID string
	if err = db.QueryRow(`INSERT INTO users(email,password_hash) VALUES($1,'') RETURNING id`, uuid.NewString()+"@example.invalid").Scan(&userID); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.Exec(`DELETE FROM users WHERE id=$1`, userID) })
	if err = db.EnsureUsagePolicy(context.Background(), userID, 300, 1, "", ""); err != nil {
		t.Fatal(err)
	}
	calls := 0
	original := http.DefaultTransport
	http.DefaultTransport = emailTestTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host != "api.openai.com" {
			return original.RoundTrip(r)
		}
		calls++
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(`{"choices":[{"message":{"content":"{\"text\":\"Synthetic quota fixture.\"}"}}],"model":"gpt-4.1-mini"}`))}, nil
	})
	t.Cleanup(func() { http.DefaultTransport = original })
	pool := NewPool(1, 10, db, nil, nil)
	defer pool.cancel()
	pool.SetTranscriptFormatter(transcriptformat.New("synthetic-test-key", ""))
	var ids []string
	for i := 0; i < 2; i++ {
		var audioID string
		if err = db.QueryRow(`INSERT INTO audio_transcriptions(filename,original_name,status,transcript_text,formatting_status,user_id) VALUES('quota.m4a','Quota fixture','completed','Synthetic quota fixture.','pending',$1) RETURNING id`, userID).Scan(&audioID); err != nil {
			t.Fatal(err)
		}
		ids = append(ids, audioID)
		if err = pool.processAudioTranscriptFormatting(Job{ID: audioID, QueueID: uuid.NewString()}); err != nil {
			t.Fatal(err)
		}
	}
	usage, err := db.AccountUsage(context.Background(), userID)
	if err != nil || usage.AIRequests != 1 || calls != 1 {
		t.Fatal("formatting bypassed or double charged cap", err)
	}
	var status, transcriptionStatus, message string
	if err = db.QueryRow(`SELECT formatting_status,status,formatting_error_message FROM audio_transcriptions WHERE id=$1`, ids[1]).Scan(&status, &transcriptionStatus, &message); err != nil || status != "skipped" || transcriptionStatus != "completed" || !strings.Contains(message, "monthly AI limit") {
		t.Fatal("capped formatting did not skip safely", err)
	}
	for _, id := range ids {
		if err = db.QueueAudioTranscriptFormatting(context.Background(), id); !database.IsUsageCap(err) {
			t.Fatal("capped account requeued formatting", err)
		}
	}
}
