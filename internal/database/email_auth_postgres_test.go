package database

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	emailservice "github.com/Shimizu-Technology/media-tools-api/internal/services/email"
)

func TestEmailChallengeConcurrentSingleUseAndPurge(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	service, _ := emailservice.New("log", "", "", "synthetic-db-proof-secret")
	address := uuid.NewString() + "@example.invalid"
	id := uuid.NewString()
	ch := EmailChallenge{ID: id, Purpose: "signup", Email: address, CodeHash: service.CodeHash(id, "456789"), PasswordHash: "synthetic-encoded-password-hash", Name: "Proof test"}
	sealed, _ := service.Seal(emailservice.CodeMessage(address, "456789", "signup"))
	t.Cleanup(func() {
		_, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE email=$1`, address)
		_, _ = db.ExecContext(context.Background(), `DELETE FROM auth_email_challenges WHERE email=$1`, address)
	})
	if issued, err := db.IssueEmailChallenge(ctx, ch, sealed); err != nil || !issued {
		t.Fatalf("issue=%v err=%v", issued, err)
	}
	var wg sync.WaitGroup
	results := make(chan error, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			results <- db.CompleteEmailChallenge(ctx, "signup", address, "456789", "synthetic-verified-password-hash", service.CodeHash, func(to, action string) (string, error) { return service.Seal(emailservice.Notice(to, action)) })
		}()
	}
	wg.Wait()
	close(results)
	accepted, rejected := 0, 0
	for err := range results {
		if err == nil {
			accepted++
		} else if errors.Is(err, ErrEmailCodeInvalid) {
			rejected++
		} else {
			t.Fatal(err)
		}
	}
	if accepted != 1 || rejected != 1 {
		t.Fatal("concurrent proof not single-use")
	}
	var userID string
	if err := db.GetContext(ctx, &userID, `SELECT id FROM users WHERE email=$1`, address); err != nil {
		t.Fatal(err)
	}
	pair, err := db.CreateFirstPartySession(ctx, userID, "ios", "Purge fixture")
	if err != nil {
		t.Fatal(err)
	}
	next, _ := RandomFirstPartyRefreshToken()
	rotated, err := db.RefreshFirstPartySessionWithSuccessor(ctx, pair.RefreshToken, next)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.ExecContext(ctx, `UPDATE auth_access_tokens SET expires_at=NOW()-INTERVAL '1 second' WHERE session_id=$1`, pair.SessionID); err != nil {
		t.Fatal(err)
	}
	if err = db.PurgeAuth(ctx); err != nil {
		t.Fatal(err)
	}
	var accessRows int
	if err = db.GetContext(ctx, &accessRows, `SELECT COUNT(*) FROM auth_access_tokens WHERE session_id=$1`, pair.SessionID); err != nil || accessRows != 0 {
		t.Fatal("expired access tokens retained")
	}
	recovered, err := db.RefreshFirstPartySessionWithSuccessor(ctx, pair.RefreshToken, next)
	if err != nil || recovered.SessionID != rotated.SessionID {
		t.Fatal("purge broke live refresh recovery")
	}
	hash, _ := authTokenHash(pair.RefreshToken, "mta_rt_")
	if _, err = db.ExecContext(ctx, `UPDATE auth_refresh_tokens SET expires_at=NOW()-INTERVAL '1 second' WHERE token_hash=$1`, hash); err != nil {
		t.Fatal(err)
	}
	if err = db.PurgeAuth(ctx); err != nil {
		t.Fatal(err)
	}
	var old int
	_ = db.GetContext(ctx, &old, `SELECT COUNT(*) FROM auth_refresh_tokens WHERE token_hash=$1`, hash)
	if old != 0 {
		t.Fatal("expired refresh retained")
	}
}
func TestEmailProofBoundToCredentialSnapshotAndAccount(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	service, _ := emailservice.New("log", "", "", "synthetic-db-proof-secret")
	userID := createPasswordTestUser(t, db)
	session, err := db.CreateFirstPartySession(ctx, userID, "ios", "Proof fixture")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.SetPasswordCredential(ctx, userID, session.SessionID, "synthetic-encoded-password-hash"); err != nil {
		t.Fatal(err)
	}
	address := uuid.NewString() + "@example.invalid"
	id := uuid.NewString()
	ch := EmailChallenge{ID: id, Purpose: "email_change", Email: address, UserID: &userID, CodeHash: service.CodeHash(id, "456789"), CredentialSnapshot: "synthetic-encoded-password-hash"}
	sealed, _ := service.Seal(emailservice.CodeMessage(address, "456789", "email_change"))
	if issued, err := db.IssueEmailChallenge(ctx, ch, sealed); err != nil || !issued {
		t.Fatal("issue email change", err)
	}
	if _, err = db.SetPasswordCredential(ctx, userID, session.SessionID, "synthetic-replacement-password-hash"); err != nil {
		t.Fatal(err)
	}
	err = db.CompleteEmailChallenge(ctx, "email_change", address, "456789", "", service.CodeHash, func(to, action string) (string, error) { return service.Seal(emailservice.Notice(to, action)) })
	if !errors.Is(err, ErrEmailCodeInvalid) {
		t.Fatal("stale email proof survived password change")
	}
}
func TestEmailOutboxExpiryAndInvalidation(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	service, _ := emailservice.New("log", "", "", "synthetic-db-proof-secret")
	address := uuid.NewString() + "@example.invalid"
	id := uuid.NewString()
	ch := EmailChallenge{ID: id, Purpose: "signup", Email: address, CodeHash: service.CodeHash(id, "456789"), PasswordHash: "synthetic-encoded-password-hash"}
	sealed, _ := service.Seal(emailservice.CodeMessage(address, "456789", "signup"))
	t.Cleanup(func() {
		_, _ = db.ExecContext(context.Background(), `DELETE FROM auth_email_challenges WHERE email=$1`, address)
	})
	if _, err := db.IssueEmailChallenge(ctx, ch, sealed); err != nil {
		t.Fatal(err)
	}
	if got, err := db.EmailForDelivery(ctx, id); err != nil || got == "" {
		t.Fatal("durable email missing")
	}
	if _, err := db.ExecContext(ctx, `UPDATE auth_email_outbox SET expires_at=$2 WHERE id=$1`, id, time.Now().Add(-time.Second)); err != nil {
		t.Fatal(err)
	}
	if got, err := db.EmailForDelivery(ctx, id); err != nil || got != "" {
		t.Fatal("expired email still deliverable")
	}
}
