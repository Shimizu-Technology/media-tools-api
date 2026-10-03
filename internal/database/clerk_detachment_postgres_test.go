package database

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
)

func createClerkDetachmentFixture(t *testing.T, db *DB) (string, string) {
	t.Helper()
	ctx := context.Background()
	clerkID := "user_" + uuid.NewString()
	var userID string
	if err := db.QueryRowContext(ctx, `
		INSERT INTO users (email, password_hash, name, clerk_id)
		VALUES ($1, '', 'Clerk detach test', $2) RETURNING id`, uuid.NewString()+"@example.com", clerkID).Scan(&userID); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `INSERT INTO auth_identities (user_id, provider, subject) VALUES ($1, 'clerk', $2)`, userID, clerkID); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, userID) })
	return userID, clerkID
}

func makeClerkDetachmentReady(t *testing.T, db *DB, userID string) {
	t.Helper()
	ctx := context.Background()
	if _, err := db.ExecContext(ctx, `
		INSERT INTO auth_passkey_credentials (credential_id, user_id, credential)
		VALUES ($1, $2, '{}')`, []byte("detach-passkey-"+uuid.NewString()), userID); err != nil {
		t.Fatal(err)
	}
	rotation, err := db.BeginRecoveryCodeRotation(ctx, userID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.ConfirmRecoveryCodeRotation(ctx, userID, rotation.ID); err != nil {
		t.Fatal(err)
	}
}

func TestDetachClerkIdentityRequiresBothRecoveryFactors(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID, clerkID := createClerkDetachmentFixture(t, db)

	status, err := db.DetachClerkIdentity(ctx, userID)
	if !errors.Is(err, ErrClerkDetachmentNotReady) || status == nil || status.Ready || !status.Linked {
		t.Fatalf("detach without factors = %#v, %v", status, err)
	}
	if _, err := db.ExecContext(ctx, `
		INSERT INTO auth_passkey_credentials (credential_id, user_id, credential)
		VALUES ($1, $2, '{}')`, []byte("one-factor-"+uuid.NewString()), userID); err != nil {
		t.Fatal(err)
	}
	status, err = db.DetachClerkIdentity(ctx, userID)
	if !errors.Is(err, ErrClerkDetachmentNotReady) || status.PasskeyCount != 1 || status.UnusedRecoveryCodes != 0 {
		t.Fatalf("detach with passkey only = %#v, %v", status, err)
	}

	var storedClerkID string
	if err := db.GetContext(ctx, &storedClerkID, `SELECT clerk_id FROM users WHERE id = $1`, userID); err != nil || storedClerkID != clerkID {
		t.Fatalf("failed readiness changed user Clerk ID = %q, %v", storedClerkID, err)
	}
	var links int
	if err := db.GetContext(ctx, &links, `SELECT COUNT(*) FROM auth_identities WHERE user_id = $1 AND provider = 'clerk'`, userID); err != nil || links != 1 {
		t.Fatalf("failed readiness changed Clerk identities = %d, %v", links, err)
	}
}

func TestDetachClerkIdentityAcceptsPasswordWithRecoveryCodes(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID, _ := createClerkDetachmentFixture(t, db)
	pair, err := db.CreateFirstPartySession(ctx, userID, "ios", "Password iPhone")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.SetPasswordCredential(ctx, userID, pair.SessionID, "$argon2id$v=19$m=19456,t=2,p=1$c2FsdHNhbHRzYWx0c2FsdA$MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY"); err != nil {
		t.Fatal(err)
	}
	rotation, err := db.BeginRecoveryCodeRotation(ctx, userID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.ConfirmRecoveryCodeRotation(ctx, userID, rotation.ID); err != nil {
		t.Fatal(err)
	}
	status, err := db.DetachClerkIdentity(ctx, userID)
	if err != nil || status.Linked || !status.Ready || !status.PasswordConfigured || status.PasskeyCount != 0 {
		t.Fatalf("password detachment = %#v, %v", status, err)
	}
}

func TestDetachClerkIdentityIsConcurrentIdempotentAndPreservesSessions(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID, _ := createClerkDetachmentFixture(t, db)
	makeClerkDetachmentReady(t, db, userID)
	pair, err := db.CreateFirstPartySession(ctx, userID, "ios", "Detach test iPhone")
	if err != nil {
		t.Fatal(err)
	}

	const callers = 8
	results := make(chan error, callers)
	var wg sync.WaitGroup
	for i := 0; i < callers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			status, err := db.DetachClerkIdentity(context.Background(), userID)
			if err == nil && (status.Linked || !status.Ready) {
				err = errors.New("successful detachment returned an invalid status")
			}
			results <- err
		}()
	}
	wg.Wait()
	close(results)
	for err := range results {
		if err != nil {
			t.Fatalf("concurrent detach failed: %v", err)
		}
	}

	var clerkID *string
	if err := db.GetContext(ctx, &clerkID, `SELECT clerk_id FROM users WHERE id = $1`, userID); err != nil || clerkID != nil {
		t.Fatalf("stored Clerk ID after detach = %#v, %v", clerkID, err)
	}
	var links int
	if err := db.GetContext(ctx, &links, `SELECT COUNT(*) FROM auth_identities WHERE user_id = $1 AND provider = 'clerk'`, userID); err != nil || links != 0 {
		t.Fatalf("Clerk identities after detach = %d, %v", links, err)
	}
	authenticated, _, err := db.GetUserByFirstPartyAccessToken(ctx, pair.AccessToken)
	if err != nil || authenticated.ID != userID {
		t.Fatalf("preserved first-party session = %#v, %v", authenticated, err)
	}
}

func TestDetachClerkIdentityCannotRaceLegacyIdentityBackfill(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID, clerkID := createClerkDetachmentFixture(t, db)
	makeClerkDetachmentReady(t, db, userID)
	// Exercise the compatibility path used for a pre-auth_identities account.
	if _, err := db.ExecContext(ctx, `DELETE FROM auth_identities WHERE user_id = $1 AND provider = 'clerk'`, userID); err != nil {
		t.Fatal(err)
	}

	const resolvers = 16
	start := make(chan struct{})
	results := make(chan error, resolvers+1)
	var wg sync.WaitGroup
	for i := 0; i < resolvers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			_, err := db.ResolveMigrationClerkUser(context.Background(), clerkID)
			if errors.Is(err, ErrClerkIdentityUnknown) {
				err = nil
			}
			results <- err
		}()
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		<-start
		_, err := db.DetachClerkIdentity(context.Background(), userID)
		results <- err
	}()
	close(start)
	wg.Wait()
	close(results)
	for err := range results {
		if err != nil {
			t.Fatalf("concurrent migration/detach operation failed: %v", err)
		}
	}

	var links int
	if err := db.GetContext(ctx, &links, `SELECT COUNT(*) FROM auth_identities WHERE user_id = $1 AND provider = 'clerk'`, userID); err != nil || links != 0 {
		t.Fatalf("legacy backfill restored detached identity = %d, %v", links, err)
	}
	var storedClerkID *string
	if err := db.GetContext(ctx, &storedClerkID, `SELECT clerk_id FROM users WHERE id = $1`, userID); err != nil || storedClerkID != nil {
		t.Fatalf("legacy Clerk ID survived detach = %#v, %v", storedClerkID, err)
	}
}

func waitForClerkLockWaiter(t *testing.T, db *DB, marker string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		var waiting int
		if err := db.GetContext(context.Background(), &waiting, `
			SELECT COUNT(*) FROM pg_stat_activity
			WHERE datname = current_database()
			  AND query LIKE '%' || $1 || '%'
			  AND wait_event_type = 'Lock'`, marker); err != nil {
			t.Fatal(err)
		}
		if waiting > 0 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s query to block on the account lock", marker)
}

func TestClerkBootstrapAndDetachmentHaveDeterministicLinearization(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()

	t.Run("detach first rejects the stale bootstrap", func(t *testing.T) {
		userID, clerkID := createClerkDetachmentFixture(t, db)
		makeClerkDetachmentReady(t, db, userID)
		next, err := RandomFirstPartyRefreshToken()
		if err != nil {
			t.Fatal(err)
		}
		blocker, err := db.BeginTxx(ctx, nil)
		if err != nil {
			t.Fatal(err)
		}
		defer blocker.Rollback()
		if _, err := blocker.ExecContext(ctx, `SELECT id FROM users WHERE id = $1 FOR UPDATE`, userID); err != nil {
			t.Fatal(err)
		}
		detachResult := make(chan error, 1)
		go func() {
			_, err := db.DetachClerkIdentity(context.Background(), userID)
			detachResult <- err
		}()
		waitForClerkLockWaiter(t, db, "clerk-detachment-lock")
		bootstrapResult := make(chan error, 1)
		go func() {
			_, err := db.CreateOrRecoverClerkMigrationSession(context.Background(), userID, clerkID, "ios", "Race iPhone", next)
			bootstrapResult <- err
		}()
		waitForClerkLockWaiter(t, db, "clerk-bootstrap-lock")
		if err := blocker.Commit(); err != nil {
			t.Fatal(err)
		}
		if err := <-detachResult; err != nil {
			t.Fatalf("detach-first detachment failed: %v", err)
		}
		if err := <-bootstrapResult; !errors.Is(err, ErrClerkIdentityUnknown) {
			t.Fatalf("stale bootstrap error = %v, want ErrClerkIdentityUnknown", err)
		}
		var links, sessions int
		if err := db.GetContext(ctx, &links, `SELECT COUNT(*) FROM auth_identities WHERE user_id = $1 AND provider = 'clerk'`, userID); err != nil {
			t.Fatal(err)
		}
		if err := db.GetContext(ctx, &sessions, `SELECT COUNT(*) FROM auth_sessions WHERE user_id = $1`, userID); err != nil {
			t.Fatal(err)
		}
		if links != 0 || sessions != 0 {
			t.Fatalf("detach-first state links=%d sessions=%d", links, sessions)
		}
	})

	t.Run("bootstrap first preserves the issued session before detach", func(t *testing.T) {
		userID, clerkID := createClerkDetachmentFixture(t, db)
		makeClerkDetachmentReady(t, db, userID)
		next, err := RandomFirstPartyRefreshToken()
		if err != nil {
			t.Fatal(err)
		}
		blocker, err := db.BeginTxx(ctx, nil)
		if err != nil {
			t.Fatal(err)
		}
		defer blocker.Rollback()
		if _, err := blocker.ExecContext(ctx, `SELECT id FROM users WHERE id = $1 FOR UPDATE`, userID); err != nil {
			t.Fatal(err)
		}
		bootstrapResult := make(chan error, 1)
		go func() {
			_, err := db.CreateOrRecoverClerkMigrationSession(context.Background(), userID, clerkID, "web", "Browser", next)
			bootstrapResult <- err
		}()
		waitForClerkLockWaiter(t, db, "clerk-bootstrap-lock")
		detachResult := make(chan error, 1)
		go func() {
			_, err := db.DetachClerkIdentity(context.Background(), userID)
			detachResult <- err
		}()
		waitForClerkLockWaiter(t, db, "clerk-detachment-lock")
		if err := blocker.Commit(); err != nil {
			t.Fatal(err)
		}
		if err := <-bootstrapResult; err != nil {
			t.Fatalf("bootstrap-first issuance failed: %v", err)
		}
		if err := <-detachResult; err != nil {
			t.Fatalf("bootstrap-first detachment failed: %v", err)
		}
		var links, sessions int
		if err := db.GetContext(ctx, &links, `SELECT COUNT(*) FROM auth_identities WHERE user_id = $1 AND provider = 'clerk'`, userID); err != nil {
			t.Fatal(err)
		}
		if err := db.GetContext(ctx, &sessions, `SELECT COUNT(*) FROM auth_sessions WHERE user_id = $1`, userID); err != nil {
			t.Fatal(err)
		}
		if links != 0 || sessions != 1 {
			t.Fatalf("bootstrap-first state links=%d sessions=%d", links, sessions)
		}
	})
}
