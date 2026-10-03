package database

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	accountservice "github.com/Shimizu-Technology/media-tools-api/internal/services/account"
	"github.com/google/uuid"
)

func createPasswordTestUser(t *testing.T, db *DB) string {
	t.Helper()
	var userID string
	if err := db.QueryRowContext(context.Background(), `
		INSERT INTO users (email, password_hash, name)
		VALUES ($1, '', 'Password test') RETURNING id`, uuid.NewString()+"@example.com").Scan(&userID); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, userID) })
	return userID
}

func TestPasswordCredentialIssuesRecoverableSessionAndReplacementRevokesOtherDevices(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := createPasswordTestUser(t, db)
	hasher, err := accountservice.NewPasswordHasher(1)
	if err != nil {
		t.Fatal(err)
	}
	hash, err := hasher.Hash(ctx, "a secure password for testing")
	if err != nil {
		t.Fatal(err)
	}
	current, err := db.CreateFirstPartySession(ctx, userID, "ios", "Current iPhone")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.SetPasswordCredential(ctx, userID, current.SessionID, hash); err != nil {
		t.Fatal(err)
	}
	credential, err := db.GetPasswordCredentialByEmail(ctx, "  "+credentialEmail(t, db, userID)+"  ")
	if err != nil {
		t.Fatal(err)
	}
	successor, err := RandomFirstPartyRefreshToken()
	if err != nil {
		t.Fatal(err)
	}
	first, err := db.CreateOrRecoverPasswordSession(ctx, userID, credential.PasswordHash, "", "ios", "Second iPhone", successor)
	if err != nil {
		t.Fatal(err)
	}
	recovered, err := db.CreateOrRecoverPasswordSession(ctx, userID, credential.PasswordHash, "", "ios", "Second iPhone", successor)
	if err != nil {
		t.Fatalf("recover identical password login: %v", err)
	}
	if recovered.RefreshToken != successor || recovered.SessionID != first.SessionID || recovered.AccessToken == first.AccessToken {
		t.Fatalf("recovered pair = %#v; first = %#v", recovered, first)
	}

	replacement, err := hasher.Hash(ctx, "a different secure password value")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.SetPasswordCredential(ctx, userID, current.SessionID, replacement); err != nil {
		t.Fatal(err)
	}
	if _, _, err := db.GetUserByFirstPartyAccessToken(ctx, first.AccessToken); !errors.Is(err, ErrSessionInvalid) {
		t.Fatalf("other device survived password replacement: %v", err)
	}
	if _, _, err := db.GetUserByFirstPartyAccessToken(ctx, current.AccessToken); err != nil {
		t.Fatalf("current device was revoked: %v", err)
	}
	if _, err := db.CreateOrRecoverPasswordSession(ctx, userID, credential.PasswordHash, "", "ios", "Old password", successor); !errors.Is(err, ErrPasswordCredentialChanged) {
		t.Fatalf("old verified hash created session: %v", err)
	}
}

func TestPasswordFailuresLockExactCredential(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := createPasswordTestUser(t, db)
	hasher, _ := accountservice.NewPasswordHasher(1)
	hash, _ := hasher.Hash(ctx, "a secure password for lock test")
	current, err := db.CreateFirstPartySession(ctx, userID, "ios", "Current")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.SetPasswordCredential(ctx, userID, current.SessionID, hash); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < passwordFailureLimit; i++ {
		if err := db.RecordPasswordFailure(ctx, userID, hash); err != nil {
			t.Fatal(err)
		}
	}
	successor, _ := RandomFirstPartyRefreshToken()
	if _, err := db.CreateOrRecoverPasswordSession(ctx, userID, hash, "", "web", "Browser", successor); !errors.Is(err, ErrPasswordCredentialLocked) {
		t.Fatalf("locked credential login = %v", err)
	}
	var firstDeadline time.Time
	if err := db.GetContext(ctx, &firstDeadline, `SELECT locked_until FROM auth_password_credentials WHERE user_id = $1`, userID); err != nil {
		t.Fatal(err)
	}
	if err := db.RecordPasswordFailure(ctx, userID, hash); err != nil {
		t.Fatal(err)
	}
	var secondDeadline time.Time
	if err := db.GetContext(ctx, &secondDeadline, `SELECT locked_until FROM auth_password_credentials WHERE user_id = $1`, userID); err != nil {
		t.Fatal(err)
	}
	if !secondDeadline.Equal(firstDeadline) {
		t.Fatalf("active lock moved from %s to %s", firstDeadline, secondDeadline)
	}
}

func TestPasswordLoginAndReplacementUseCompatibleLockOrder(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := createPasswordTestUser(t, db)
	hasher, err := accountservice.NewPasswordHasher(2)
	if err != nil {
		t.Fatal(err)
	}
	current, err := db.CreateFirstPartySession(ctx, userID, "ios", "Current")
	if err != nil {
		t.Fatal(err)
	}
	initial, err := hasher.Hash(ctx, "initial password for race testing")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.SetPasswordCredential(ctx, userID, current.SessionID, initial); err != nil {
		t.Fatal(err)
	}

	for i := 0; i < 8; i++ {
		credential, err := db.GetPasswordCredentialByEmail(ctx, credentialEmail(t, db, userID))
		if err != nil {
			t.Fatal(err)
		}
		replacement, err := hasher.Hash(ctx, fmt.Sprintf("replacement password number %02d", i))
		if err != nil {
			t.Fatal(err)
		}
		successor, err := RandomFirstPartyRefreshToken()
		if err != nil {
			t.Fatal(err)
		}
		start := make(chan struct{})
		errs := make(chan error, 2)
		var workers sync.WaitGroup
		workers.Add(2)
		go func() {
			defer workers.Done()
			<-start
			_, err := db.CreateOrRecoverPasswordSession(ctx, userID, credential.PasswordHash, "", "ios", "Racing login", successor)
			if errors.Is(err, ErrPasswordCredentialChanged) {
				err = nil
			}
			errs <- err
		}()
		go func() {
			defer workers.Done()
			<-start
			_, err := db.SetPasswordCredential(ctx, userID, current.SessionID, replacement)
			errs <- err
		}()
		close(start)
		workers.Wait()
		close(errs)
		for err := range errs {
			if err != nil {
				t.Fatalf("concurrent password operation %d failed: %v", i, err)
			}
		}
	}
}

func credentialEmail(t *testing.T, db *DB, userID string) string {
	t.Helper()
	var email string
	if err := db.GetContext(context.Background(), &email, `SELECT email FROM users WHERE id = $1`, userID); err != nil {
		t.Fatal(err)
	}
	return email
}
