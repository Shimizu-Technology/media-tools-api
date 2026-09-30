package database

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
)

func insertBootstrapTestUser(t *testing.T, db *DB) string {
	t.Helper()
	var userID string
	if err := db.QueryRowContext(context.Background(), `
		INSERT INTO users (email, password_hash, name)
		VALUES ($1, '', 'Bootstrap Test') RETURNING id`,
		uuid.NewString()+"@example.com").Scan(&userID); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if _, err := db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, userID); err != nil {
			t.Errorf("cleanup bootstrap user: %v", err)
		}
	})
	return userID
}

func authRowCountForUser(t *testing.T, db *DB, table, userID string) int {
	t.Helper()
	var count int
	query := `SELECT COUNT(*) FROM ` + table + ` a JOIN auth_sessions s ON s.id = a.session_id WHERE s.user_id = $1`
	if err := db.GetContext(context.Background(), &count, query, userID); err != nil {
		t.Fatal(err)
	}
	return count
}

func sessionClientType(t *testing.T, db *DB, sessionID string) string {
	t.Helper()
	var clientType string
	if err := db.GetContext(context.Background(), &clientType, `SELECT client_type FROM auth_sessions WHERE id = $1`, sessionID); err != nil {
		t.Fatal(err)
	}
	return clientType
}

func TestCreateOrRecoverFirstPartySessionExactRetryAndWebSupport(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := insertBootstrapTestUser(t, db)
	next, err := RandomFirstPartyRefreshToken()
	if err != nil {
		t.Fatal(err)
	}

	first, err := db.CreateOrRecoverFirstPartySession(ctx, userID, "ios", "Test iPhone", next)
	if err != nil {
		t.Fatal(err)
	}
	recovered, err := db.CreateOrRecoverFirstPartySession(ctx, userID, "ios", "Renamed iPhone", next)
	if err != nil {
		t.Fatal(err)
	}
	if recovered.SessionID != first.SessionID || recovered.RefreshToken != next || recovered.AccessToken == first.AccessToken {
		t.Fatalf("exact retry created different session or credentials: first=%#v recovered=%#v", first, recovered)
	}
	var sessions, issuances int
	if err := db.GetContext(ctx, &sessions, `SELECT COUNT(*) FROM auth_sessions WHERE user_id = $1`, userID); err != nil {
		t.Fatal(err)
	}
	if err := db.GetContext(ctx, &issuances, `SELECT COUNT(*) FROM auth_session_bootstrap_issuances WHERE user_id = $1`, userID); err != nil {
		t.Fatal(err)
	}
	if sessions != 1 || issuances != 1 {
		t.Fatalf("exact retry state: sessions=%d issuances=%d", sessions, issuances)
	}
	var storedHash string
	if err := db.GetContext(ctx, &storedHash, `SELECT successor_hash FROM auth_session_bootstrap_issuances WHERE user_id = $1`, userID); err != nil {
		t.Fatal(err)
	}
	wantHash, _ := refreshSuccessorHash(next)
	if storedHash != wantHash || storedHash == next {
		t.Fatalf("stored successor = %q, want only SHA-256 hash", storedHash)
	}

	webNext, err := RandomFirstPartyRefreshToken()
	if err != nil {
		t.Fatal(err)
	}
	web, err := db.CreateOrRecoverFirstPartySession(ctx, userID, "web", "Browser", webNext)
	if err != nil || sessionClientType(t, db, web.SessionID) != "web" {
		t.Fatalf("database web bootstrap = %#v, %v", web, err)
	}
}

func TestCreateOrRecoverFirstPartySessionSerializesConcurrentRetry(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := insertBootstrapTestUser(t, db)
	next, err := RandomFirstPartyRefreshToken()
	if err != nil {
		t.Fatal(err)
	}

	const workers = 8
	start := make(chan struct{})
	type result struct {
		pair *AuthTokenPair
		err  error
	}
	results := make(chan result, workers)
	var wait sync.WaitGroup
	for i := 0; i < workers; i++ {
		wait.Add(1)
		go func() {
			defer wait.Done()
			<-start
			pair, err := db.CreateOrRecoverFirstPartySession(ctx, userID, "ios", "Concurrent iPhone", next)
			results <- result{pair: pair, err: err}
		}()
	}
	close(start)
	wait.Wait()
	close(results)

	var sessionID string
	accessTokens := make(map[string]struct{}, workers)
	for result := range results {
		if result.err != nil {
			t.Fatal(result.err)
		}
		if sessionID == "" {
			sessionID = result.pair.SessionID
		}
		if result.pair.SessionID != sessionID || result.pair.RefreshToken != next {
			t.Fatalf("concurrent retry returned another session: %#v", result.pair)
		}
		accessTokens[result.pair.AccessToken] = struct{}{}
	}
	if len(accessTokens) != workers {
		t.Fatalf("fresh access credentials = %d, want %d", len(accessTokens), workers)
	}
	var sessions int
	if err := db.GetContext(ctx, &sessions, `SELECT COUNT(*) FROM auth_sessions WHERE user_id = $1`, userID); err != nil || sessions != 1 {
		t.Fatalf("concurrent sessions = %d, %v", sessions, err)
	}
}

func TestCreateOrRecoverFirstPartySessionRejectsUnavailableSuccessorsWithoutMintingAccess(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	ownerID := insertBootstrapTestUser(t, db)
	otherID := insertBootstrapTestUser(t, db)

	activeNext, err := RandomFirstPartyRefreshToken()
	if err != nil {
		t.Fatal(err)
	}
	active, err := db.CreateOrRecoverFirstPartySession(ctx, ownerID, "ios", "Owner phone", activeNext)
	if err != nil {
		t.Fatal(err)
	}
	activeAccess := authRowCountForUser(t, db, "auth_access_tokens", ownerID)
	if _, err := db.CreateOrRecoverFirstPartySession(ctx, otherID, "ios", "Other phone", activeNext); !errors.Is(err, ErrSessionInvalid) {
		t.Fatalf("other user successor = %v", err)
	}
	if _, err := db.CreateOrRecoverFirstPartySession(ctx, ownerID, "android", "Other client", activeNext); !errors.Is(err, ErrSessionInvalid) {
		t.Fatalf("wrong client successor = %v", err)
	}
	if got := authRowCountForUser(t, db, "auth_access_tokens", ownerID); got != activeAccess {
		t.Fatalf("unavailable successor minted access: before=%d after=%d", activeAccess, got)
	}
	var otherSessions int
	if err := db.GetContext(ctx, &otherSessions, `SELECT COUNT(*) FROM auth_sessions WHERE user_id = $1`, otherID); err != nil || otherSessions != 0 {
		t.Fatalf("other-user collision created session: %d, %v", otherSessions, err)
	}

	// A refresh credential created outside bootstrap has no issuance row. Its
	// unique-token collision must still roll back the attempted session/access.
	existing, err := db.CreateFirstPartySession(ctx, ownerID, "ios", "Existing phone")
	if err != nil {
		t.Fatal(err)
	}
	otherAccess := authRowCountForUser(t, db, "auth_access_tokens", otherID)
	if _, err := db.CreateOrRecoverFirstPartySession(ctx, otherID, "ios", "Collision phone", existing.RefreshToken); !errors.Is(err, ErrSessionInvalid) {
		t.Fatalf("unlinked successor collision = %v", err)
	}
	if got := authRowCountForUser(t, db, "auth_access_tokens", otherID); got != otherAccess {
		t.Fatalf("collision rollback left access credential: before=%d after=%d", otherAccess, got)
	}

	// Keep the first pair live until assertions finish so a failed call cannot
	// be mistaken for cleanup or expiry.
	if _, _, err := db.GetUserByFirstPartyAccessToken(ctx, active.AccessToken); err != nil {
		t.Fatalf("valid owner session was damaged: %v", err)
	}
}

func TestCreateOrRecoverFirstPartySessionLifetimeAndInvalidStatePruning(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := insertBootstrapTestUser(t, db)

	create := func(t *testing.T) (*AuthTokenPair, string) {
		t.Helper()
		next, err := RandomFirstPartyRefreshToken()
		if err != nil {
			t.Fatal(err)
		}
		pair, err := db.CreateOrRecoverFirstPartySession(ctx, userID, "ios", "iPhone", next)
		if err != nil {
			t.Fatal(err)
		}
		return pair, next
	}

	t.Run("older than ceremony window but active", func(t *testing.T) {
		pair, next := create(t)
		hash, _ := refreshSuccessorHash(next)
		if _, err := db.ExecContext(ctx, `UPDATE auth_session_bootstrap_issuances SET created_at = $2 WHERE successor_hash = $1`, hash, time.Now().Add(-48*time.Hour)); err != nil {
			t.Fatal(err)
		}
		recovered, err := db.CreateOrRecoverFirstPartySession(ctx, userID, "ios", "iPhone", next)
		if err != nil || recovered.SessionID != pair.SessionID || recovered.AccessToken == pair.AccessToken {
			t.Fatalf("active long-delay recovery = %#v, %v", recovered, err)
		}
	})

	for _, test := range []struct {
		name   string
		mutate func(*testing.T, *AuthTokenPair, string)
	}{
		{name: "revoked", mutate: func(t *testing.T, pair *AuthTokenPair, _ string) {
			_, err := db.ExecContext(ctx, `UPDATE auth_sessions SET revoked_at = NOW() WHERE id = $1`, pair.SessionID)
			if err != nil {
				t.Fatal(err)
			}
		}},
		{name: "expired", mutate: func(t *testing.T, pair *AuthTokenPair, next string) {
			hash, _ := refreshSuccessorHash(next)
			if _, err := db.ExecContext(ctx, `UPDATE auth_sessions SET inactive_expires_at = NOW() - INTERVAL '1 second' WHERE id = $1`, pair.SessionID); err != nil {
				t.Fatal(err)
			}
			if _, err := db.ExecContext(ctx, `UPDATE auth_refresh_tokens SET expires_at = NOW() - INTERVAL '1 second' WHERE token_hash = $1`, hash); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "consumed", mutate: func(t *testing.T, _ *AuthTokenPair, next string) {
			hash, _ := refreshSuccessorHash(next)
			if _, err := db.ExecContext(ctx, `UPDATE auth_refresh_tokens SET consumed_at = NOW() WHERE token_hash = $1`, hash); err != nil {
				t.Fatal(err)
			}
		}},
	} {
		t.Run(test.name, func(t *testing.T) {
			pair, next := create(t)
			before := authRowCountForUser(t, db, "auth_access_tokens", userID)
			test.mutate(t, pair, next)
			if _, err := db.CreateOrRecoverFirstPartySession(ctx, userID, "ios", "iPhone", next); !errors.Is(err, ErrSessionInvalid) {
				t.Fatalf("invalid session retry = %v", err)
			}
			if after := authRowCountForUser(t, db, "auth_access_tokens", userID); after != before {
				t.Fatalf("invalid session minted access: before=%d after=%d", before, after)
			}
			// The invalid successor remains a tombstone for this transaction.
			// A later, unrelated bootstrap performs bounded cleanup without ever
			// allowing the invalid credential to create a new session.
			maintenanceNext, err := RandomFirstPartyRefreshToken()
			if err != nil {
				t.Fatal(err)
			}
			if _, err := db.CreateOrRecoverFirstPartySession(ctx, userID, "ios", "Maintenance phone", maintenanceNext); err != nil {
				t.Fatal(err)
			}
			var issuance int
			hash, _ := refreshSuccessorHash(next)
			if err := db.GetContext(ctx, &issuance, `SELECT COUNT(*) FROM auth_session_bootstrap_issuances WHERE successor_hash = $1`, hash); err != nil || issuance != 0 {
				t.Fatalf("invalid issuance was not pruned: %d, %v", issuance, err)
			}
		})
	}

	t.Run("missing refresh stays a tombstone", func(t *testing.T) {
		pair, next := create(t)
		hash, _ := refreshSuccessorHash(next)
		before := authRowCountForUser(t, db, "auth_access_tokens", userID)
		if _, err := db.ExecContext(ctx, `DELETE FROM auth_refresh_tokens WHERE token_hash = $1`, hash); err != nil {
			t.Fatal(err)
		}
		for attempt := 0; attempt < 2; attempt++ {
			if _, err := db.CreateOrRecoverFirstPartySession(ctx, userID, "ios", "iPhone", next); !errors.Is(err, ErrSessionInvalid) {
				t.Fatalf("missing refresh retry %d = %v", attempt, err)
			}
		}
		if after := authRowCountForUser(t, db, "auth_access_tokens", userID); after != before {
			t.Fatalf("missing refresh minted access: before=%d after=%d", before, after)
		}
		var issuance int
		if err := db.GetContext(ctx, &issuance, `SELECT COUNT(*) FROM auth_session_bootstrap_issuances WHERE successor_hash = $1 AND session_id = $2`, hash, pair.SessionID); err != nil || issuance != 1 {
			t.Fatalf("missing-refresh tombstone = %d, %v", issuance, err)
		}
	})

	t.Run("pruning is account scoped", func(t *testing.T) {
		otherID := insertBootstrapTestUser(t, db)
		pair, next := create(t)
		hash, _ := refreshSuccessorHash(next)
		if _, err := db.ExecContext(ctx, `UPDATE auth_sessions SET revoked_at = NOW() WHERE id = $1`, pair.SessionID); err != nil {
			t.Fatal(err)
		}
		otherNext, err := RandomFirstPartyRefreshToken()
		if err != nil {
			t.Fatal(err)
		}
		if _, err := db.CreateOrRecoverFirstPartySession(ctx, otherID, "ios", "Other account", otherNext); err != nil {
			t.Fatal(err)
		}
		var issuance int
		if err := db.GetContext(ctx, &issuance, `SELECT COUNT(*) FROM auth_session_bootstrap_issuances WHERE successor_hash = $1`, hash); err != nil || issuance != 1 {
			t.Fatalf("other account pruned issuance: %d, %v", issuance, err)
		}
		ownerNext, err := RandomFirstPartyRefreshToken()
		if err != nil {
			t.Fatal(err)
		}
		if _, err := db.CreateOrRecoverFirstPartySession(ctx, userID, "ios", "Owner maintenance", ownerNext); err != nil {
			t.Fatal(err)
		}
		if err := db.GetContext(ctx, &issuance, `SELECT COUNT(*) FROM auth_session_bootstrap_issuances WHERE successor_hash = $1`, hash); err != nil || issuance != 0 {
			t.Fatalf("owner cleanup left invalid issuance: %d, %v", issuance, err)
		}
	})
}

func TestAuthSessionBootstrapMigrationDownAndUp(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()

	readMigration := func(name string) string {
		t.Helper()
		contents, err := os.ReadFile(filepath.Join("..", "..", "migrations", name))
		if err != nil {
			t.Fatal(err)
		}
		return string(contents)
	}
	var exists bool
	if _, err := tx.ExecContext(ctx, readMigration("050_auth_session_bootstrap_issuances.down.sql")); err != nil {
		t.Fatalf("apply migration 050 down: %v", err)
	}
	if err := tx.GetContext(ctx, &exists, `SELECT to_regclass('auth_session_bootstrap_issuances') IS NOT NULL`); err != nil || exists {
		t.Fatalf("bootstrap issuance table remained after down: exists=%t err=%v", exists, err)
	}
	if _, err := tx.ExecContext(ctx, readMigration("050_auth_session_bootstrap_issuances.up.sql")); err != nil {
		t.Fatalf("apply migration 050 up: %v", err)
	}
	if err := tx.GetContext(ctx, &exists, `SELECT to_regclass('auth_session_bootstrap_issuances') IS NOT NULL`); err != nil || !exists {
		t.Fatalf("bootstrap issuance table missing after up: exists=%t err=%v", exists, err)
	}
	var columns int
	if err := tx.GetContext(ctx, &columns, `
		SELECT COUNT(*) FROM information_schema.columns
		WHERE table_name = 'auth_session_bootstrap_issuances'
		  AND column_name IN ('successor_hash', 'session_id', 'user_id', 'client_type', 'created_at')`); err != nil || columns != 5 {
		t.Fatalf("bootstrap issuance columns = %d, %v", columns, err)
	}
	if err := tx.GetContext(ctx, &exists, `SELECT to_regclass('auth_session_bootstrap_issuances_user_id_idx') IS NOT NULL`); err != nil || !exists {
		t.Fatalf("bootstrap issuance user index missing after up: exists=%t err=%v", exists, err)
	}
}
