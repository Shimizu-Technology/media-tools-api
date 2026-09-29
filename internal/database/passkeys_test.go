package database

import (
	"context"
	"errors"
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
