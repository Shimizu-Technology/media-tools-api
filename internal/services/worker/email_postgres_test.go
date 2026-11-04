package worker

import (
	"context"
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
