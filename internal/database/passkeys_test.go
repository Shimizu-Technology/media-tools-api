package database

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/go-webauthn/webauthn/webauthn"
	"github.com/google/uuid"
)

func insertPasskeyTestUser(t *testing.T, db *DB) string {
	t.Helper()
	var id string
	if err := db.QueryRowContext(context.Background(), `
		INSERT INTO users (email, password_hash, name)
		VALUES ($1, '', 'Passkey Test') RETURNING id`, uuid.NewString()+"@example.com").Scan(&id); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, id) })
	return id
}

func TestPasskeySessionIssuanceRecoversExactlyAndExpires(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := insertPasskeyTestUser(t, db)
	credential := &webauthn.Credential{ID: []byte("recoverable-passkey-credential-123"), PublicKey: []byte("test-public-key")}
	if err := db.AddPasskeyCredential(ctx, userID, credential); err != nil {
		t.Fatal(err)
	}
	ceremony, err := db.CreatePasskeyCeremony(ctx, "login", "", "", &webauthn.SessionData{Challenge: "recoverable", Expires: time.Now().Add(5 * time.Minute)})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.ConsumePasskeyCeremony(ctx, ceremony, "login", "", ""); err != nil {
		t.Fatal(err)
	}
	next, err := RandomFirstPartyRefreshToken()
	if err != nil {
		t.Fatal(err)
	}
	credential.Authenticator.SignCount = 1
	issued, err := db.CompletePasskeyLogin(ctx, ceremony, userID, credential, 0, "web", "Browser", next)
	if err != nil || issued.RefreshToken != next {
		t.Fatalf("complete passkey login = %#v, %v", issued, err)
	}

	type result struct {
		pair *AuthTokenPair
		err  error
	}
	results := make(chan result, 2)
	var workers sync.WaitGroup
	for i := 0; i < 2; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			pair, err := db.RecoverPasskeyLogin(ctx, ceremony, next)
			results <- result{pair: pair, err: err}
		}()
	}
	workers.Wait()
	close(results)
	for result := range results {
		if result.err != nil || result.pair.SessionID != issued.SessionID || result.pair.RefreshToken != next || result.pair.AccessToken == issued.AccessToken {
			t.Fatalf("concurrent passkey recovery = %#v, %v", result.pair, result.err)
		}
	}
	wrong, err := RandomFirstPartyRefreshToken()
	if err != nil {
		t.Fatal(err)
	}
	var accessBefore int
	if err := db.GetContext(ctx, &accessBefore, `SELECT COUNT(*) FROM auth_access_tokens WHERE session_id = $1`, issued.SessionID); err != nil {
		t.Fatal(err)
	}
	if _, err := db.RecoverPasskeyLogin(ctx, ceremony, wrong); !errors.Is(err, ErrPasskeyCeremonyInvalid) {
		t.Fatalf("wrong successor recovery = %v", err)
	}
	var accessAfter int
	if err := db.GetContext(ctx, &accessAfter, `SELECT COUNT(*) FROM auth_access_tokens WHERE session_id = $1`, issued.SessionID); err != nil || accessAfter != accessBefore {
		t.Fatalf("wrong successor minted access: before=%d after=%d err=%v", accessBefore, accessAfter, err)
	}
	if _, err := db.ExecContext(ctx, `UPDATE auth_passkey_ceremonies SET completed_at = $2 WHERE id = $1`, ceremony, time.Now().UTC().Add(-credentialIssuanceRetryWindow-time.Second)); err != nil {
		t.Fatal(err)
	}
	if _, err := db.RecoverPasskeyLogin(ctx, ceremony, next); !errors.Is(err, ErrPasskeyCeremonyInvalid) {
		t.Fatalf("expired passkey recovery = %v", err)
	}
	var sessions int
	if err := db.GetContext(ctx, &sessions, `SELECT COUNT(*) FROM auth_sessions WHERE user_id = $1`, userID); err != nil || sessions != 1 {
		t.Fatalf("passkey recovery session count = %d, %v", sessions, err)
	}
}

func TestPasskeySessionRecoveryHonorsRevocationAndRejectsReplayedSuccessor(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := insertPasskeyTestUser(t, db)
	credential := &webauthn.Credential{ID: []byte("revoked-passkey-credential-123456"), PublicKey: []byte("test-public-key")}
	if err := db.AddPasskeyCredential(ctx, userID, credential); err != nil {
		t.Fatal(err)
	}
	makeConsumedCeremony := func(challenge string) string {
		id, err := db.CreatePasskeyCeremony(ctx, "login", "", "", &webauthn.SessionData{Challenge: challenge, Expires: time.Now().Add(5 * time.Minute)})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := db.ConsumePasskeyCeremony(ctx, id, "login", "", ""); err != nil {
			t.Fatal(err)
		}
		return id
	}
	firstCeremony := makeConsumedCeremony("first")
	firstNext, _ := RandomFirstPartyRefreshToken()
	credential.Authenticator.SignCount = 1
	first, err := db.CompletePasskeyLogin(ctx, firstCeremony, userID, credential, 0, "ios", "Phone", firstNext)
	if err != nil {
		t.Fatal(err)
	}
	if revoked, err := db.RevokeFirstPartySession(ctx, userID, first.SessionID); err != nil || !revoked {
		t.Fatalf("revoke passkey session = %v, %v", revoked, err)
	}
	if _, err := db.RecoverPasskeyLogin(ctx, firstCeremony, firstNext); !errors.Is(err, ErrPasskeyCeremonyInvalid) {
		t.Fatalf("revoked passkey recovery = %v", err)
	}

	secondCeremony := makeConsumedCeremony("second")
	credential.Authenticator.SignCount = 2
	if _, err := db.CompletePasskeyLogin(ctx, secondCeremony, userID, credential, 1, "ios", "Phone", firstNext); !errors.Is(err, ErrPasskeyCeremonyInvalid) {
		t.Fatalf("replayed successor completion = %v", err)
	}
	var completed int
	if err := db.GetContext(ctx, &completed, `SELECT COUNT(*) FROM auth_passkey_ceremonies WHERE id = $1 AND completed_at IS NOT NULL`, secondCeremony); err != nil || completed != 0 {
		t.Fatalf("replayed successor linked ceremony = %d, %v", completed, err)
	}
	stored, err := db.ListPasskeysForUser(ctx, userID)
	if err != nil || len(stored) != 1 || stored[0].Revision != 1 {
		t.Fatalf("replayed successor changed passkey state = %#v, %v", stored, err)
	}
	var sessions int
	if err := db.GetContext(ctx, &sessions, `SELECT COUNT(*) FROM auth_sessions WHERE user_id = $1`, userID); err != nil || sessions != 1 {
		t.Fatalf("replayed successor created session: count=%d err=%v", sessions, err)
	}
}

func TestPasskeyCeremonyIsBoundExpiresAndCannotReplay(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	first := insertPasskeyTestUser(t, db)
	second := insertPasskeyTestUser(t, db)
	session := &webauthn.SessionData{Challenge: "test-challenge", Expires: time.Now().Add(5 * time.Minute)}
	id, err := db.CreatePasskeyCeremony(ctx, "register", first, "first-party:session-a", session)
	if err != nil {
		t.Fatal(err)
	}
	for _, wrong := range []struct{ kind, user, binding string }{
		{"login", "", ""},
		{"register", second, "first-party:session-a"},
		{"register", first, "first-party:session-b"},
	} {
		if _, err := db.ConsumePasskeyCeremony(ctx, id, wrong.kind, wrong.user, wrong.binding); !errors.Is(err, ErrPasskeyCeremonyInvalid) {
			t.Fatalf("wrong ceremony scope %+v: %v", wrong, err)
		}
	}
	used, err := db.ConsumePasskeyCeremony(ctx, id, "register", first, "first-party:session-a")
	if err != nil || used.Challenge != session.Challenge {
		t.Fatalf("valid ceremony: %#v, %v", used, err)
	}
	if _, err := db.ConsumePasskeyCeremony(ctx, id, "register", first, "first-party:session-a"); !errors.Is(err, ErrPasskeyCeremonyInvalid) {
		t.Fatalf("replayed ceremony: %v", err)
	}

	expiredID, err := db.CreatePasskeyCeremony(ctx, "login", "", "", session)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `UPDATE auth_passkey_ceremonies SET expires_at = NOW() - INTERVAL '1 second' WHERE id = $1`, expiredID); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ConsumePasskeyCeremony(ctx, expiredID, "login", "", ""); !errors.Is(err, ErrPasskeyCeremonyInvalid) {
		t.Fatalf("expired ceremony: %v", err)
	}
	if _, err := db.ExecContext(ctx, `UPDATE auth_passkey_ceremonies SET expires_at = NOW() - INTERVAL '2 days' WHERE id = $1`, expiredID); err != nil {
		t.Fatal(err)
	}
	if _, err := db.CreatePasskeyCeremony(ctx, "login", "", "", session); err != nil {
		t.Fatal(err)
	}
	var oldRows int
	if err := db.GetContext(ctx, &oldRows, `SELECT COUNT(*) FROM auth_passkey_ceremonies WHERE id = $1`, expiredID); err != nil || oldRows != 0 {
		t.Fatalf("old ceremony rows after prune = %d, %v", oldRows, err)
	}
}

func TestPasskeyCredentialCannotMoveAccountsOrOverwriteNewerState(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	first := insertPasskeyTestUser(t, db)
	second := insertPasskeyTestUser(t, db)
	credential := &webauthn.Credential{ID: []byte("unique-passkey-credential-123456789"), PublicKey: []byte("test-public-key")}
	if err := db.AddPasskeyCredential(ctx, first, credential); err != nil {
		t.Fatal(err)
	}
	if err := db.AddPasskeyCredential(ctx, second, credential); !errors.Is(err, ErrPasskeyCredentialExists) {
		t.Fatalf("cross-account credential collision: %v", err)
	}
	owner, err := db.GetPasskeyCredentialOwner(ctx, credential.ID)
	if err != nil || owner != first {
		t.Fatalf("passkey owner = %q, %v", owner, err)
	}
	stored, err := db.ListPasskeysForUser(ctx, first)
	if err != nil || len(stored) != 1 || stored[0].Revision != 0 {
		t.Fatalf("stored passkeys = %#v, %v", stored, err)
	}
	credential.Authenticator.SignCount = 1
	if err := db.UpdatePasskeyCredential(ctx, first, credential, 0); err != nil {
		t.Fatal(err)
	}
	credential.Authenticator.SignCount = 0
	if err := db.UpdatePasskeyCredential(ctx, first, credential, 0); !errors.Is(err, ErrPasskeyCredentialChanged) {
		t.Fatalf("stale assertion overwrote state: %v", err)
	}
	stored, err = db.ListPasskeysForUser(ctx, first)
	if err != nil || stored[0].Revision != 1 || stored[0].Credential.Authenticator.SignCount != 1 {
		t.Fatalf("newer credential state = %#v, %v", stored, err)
	}
	if err := db.UpdatePasskeyCredential(ctx, second, credential, 1); !errors.Is(err, ErrPasskeyCredentialChanged) {
		t.Fatalf("other user updated credential: %v", err)
	}
}
