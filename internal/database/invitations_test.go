package database

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestInvitationRedeemCreatesNativeUserSessionOnce(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	email := uuid.NewString() + "@example.com"
	invitation, token, err := db.CreateInvitation(ctx, email, "Invited User")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = db.ExecContext(context.Background(), `DELETE FROM auth_invitations WHERE id = $1`, invitation.ID)
	})

	next, err := RandomFirstPartyRefreshToken()
	if err != nil {
		t.Fatal(err)
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
			pair, err := db.RedeemInvitation(ctx, token, "web", "Browser", next)
			results <- result{pair: pair, err: err}
		}()
	}
	workers.Wait()
	close(results)
	var pairs []*AuthTokenPair
	for result := range results {
		if result.err != nil {
			t.Fatal(result.err)
		}
		pairs = append(pairs, result.pair)
	}
	if len(pairs) != 2 || pairs[0].SessionID != pairs[1].SessionID ||
		pairs[0].RefreshToken != next || pairs[1].RefreshToken != next ||
		pairs[0].AccessToken == pairs[1].AccessToken {
		t.Fatalf("concurrent exact retry did not recover one session: %#v", pairs)
	}

	var user struct {
		ID      string  `db:"id"`
		ClerkID *string `db:"clerk_id"`
	}
	if err := db.GetContext(ctx, &user, `SELECT id, clerk_id FROM users WHERE email = $1`, email); err != nil {
		t.Fatalf("load invited user: %v", err)
	}
	t.Cleanup(func() { _, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, user.ID) })
	if user.ClerkID != nil {
		t.Fatalf("invitation linked Clerk ID: %#v", user.ClerkID)
	}
	var sessions int
	if err := db.GetContext(ctx, &sessions, `SELECT COUNT(*) FROM auth_sessions WHERE user_id = $1`, user.ID); err != nil || sessions != 1 {
		t.Fatalf("session count = %d, %v", sessions, err)
	}
	wrong, err := RandomFirstPartyRefreshToken()
	if err != nil {
		t.Fatal(err)
	}
	var accessBefore int
	if err := db.GetContext(ctx, &accessBefore, `SELECT COUNT(*) FROM auth_access_tokens WHERE session_id = $1`, pairs[0].SessionID); err != nil {
		t.Fatal(err)
	}
	if _, err := db.RedeemInvitation(ctx, token, "web", "Browser", wrong); !errors.Is(err, ErrInvitationInvalid) {
		t.Fatalf("wrong successor retry = %v", err)
	}
	var accessAfter int
	if err := db.GetContext(ctx, &accessAfter, `SELECT COUNT(*) FROM auth_access_tokens WHERE session_id = $1`, pairs[0].SessionID); err != nil || accessAfter != accessBefore {
		t.Fatalf("wrong successor minted access: before=%d after=%d err=%v", accessBefore, accessAfter, err)
	}
}

func TestInvitationRejectsExpiredAndExistingEmail(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := insertPasskeyTestUser(t, db)
	var email string
	if err := db.GetContext(ctx, &email, `SELECT email FROM users WHERE id = $1`, userID); err != nil {
		t.Fatal(err)
	}
	if _, _, err := db.CreateInvitation(ctx, email, "Existing User"); !errors.Is(err, ErrInvitationEmailExists) {
		t.Fatalf("existing email invitation error = %v", err)
	}

	invitation, token, err := db.CreateInvitation(ctx, uuid.NewString()+"@example.com", "Expired User")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = db.ExecContext(context.Background(), `DELETE FROM auth_invitations WHERE id = $1`, invitation.ID)
	})
	if _, err := db.ExecContext(ctx, `UPDATE auth_invitations SET expires_at = NOW() - INTERVAL '1 second' WHERE id = $1`, invitation.ID); err != nil {
		t.Fatal(err)
	}
	next, err := RandomFirstPartyRefreshToken()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.RedeemInvitation(ctx, token, "ios", "Phone", next); !errors.Is(err, ErrInvitationInvalid) {
		t.Fatalf("expired invitation error = %v", err)
	}
}

func TestInvitationExactRetryExpiresAndHonorsSessionRevocation(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	for _, test := range []struct {
		name   string
		mutate func(*AuthTokenPair, *AuthInvitation)
	}{
		{
			name: "retry window expired",
			mutate: func(_ *AuthTokenPair, invitation *AuthInvitation) {
				_, err := db.ExecContext(ctx, `UPDATE auth_invitations SET consumed_at = $2 WHERE id = $1`, invitation.ID, time.Now().UTC().Add(-credentialIssuanceRetryWindow-time.Second))
				if err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "session revoked",
			mutate: func(pair *AuthTokenPair, _ *AuthInvitation) {
				if revoked, err := db.RevokeFirstPartySession(ctx, pair.UserID, pair.SessionID); err != nil || !revoked {
					t.Fatalf("revoke session = %v, %v", revoked, err)
				}
			},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			email := uuid.NewString() + "@example.com"
			invitation, token, err := db.CreateInvitation(ctx, email, "Retry User")
			if err != nil {
				t.Fatal(err)
			}
			next, err := RandomFirstPartyRefreshToken()
			if err != nil {
				t.Fatal(err)
			}
			pair, err := db.RedeemInvitation(ctx, token, "ios", "Phone", next)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, pair.UserID) })
			test.mutate(pair, invitation)
			if _, err := db.RedeemInvitation(ctx, token, "ios", "Phone", next); !errors.Is(err, ErrInvitationInvalid) {
				t.Fatalf("retry after boundary = %v", err)
			}
		})
	}
}

func TestInvitationReplayedSuccessorCreatesNothing(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	ownerID := insertPasskeyTestUser(t, db)
	existing, err := db.CreateFirstPartySession(ctx, ownerID, "ios", "Existing phone")
	if err != nil {
		t.Fatal(err)
	}
	email := uuid.NewString() + "@example.com"
	invitation, token, err := db.CreateInvitation(ctx, email, "No Account")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = db.ExecContext(context.Background(), `DELETE FROM auth_invitations WHERE id = $1`, invitation.ID)
	})
	if _, err := db.RedeemInvitation(ctx, token, "android", "Phone", existing.RefreshToken); !errors.Is(err, ErrInvitationInvalid) {
		t.Fatalf("replayed successor = %v", err)
	}
	var users, consumed int
	if err := db.GetContext(ctx, &users, `SELECT COUNT(*) FROM users WHERE email = $1`, email); err != nil {
		t.Fatal(err)
	}
	if err := db.GetContext(ctx, &consumed, `SELECT COUNT(*) FROM auth_invitations WHERE id = $1 AND consumed_at IS NOT NULL`, invitation.ID); err != nil {
		t.Fatal(err)
	}
	if users != 0 || consumed != 0 {
		t.Fatalf("replayed successor changed state: users=%d consumed=%d", users, consumed)
	}
}

func TestFindOrCreateClerkUserDoesNotLinkByEmail(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	email := uuid.NewString() + "@example.com"
	var nativeID string
	if err := db.QueryRowContext(ctx, `
		INSERT INTO users (email, password_hash, name)
		VALUES ($1, '', 'Native User') RETURNING id`, email).Scan(&nativeID); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, nativeID) })

	if _, err := db.FindOrCreateClerkUser(ctx, "user_"+uuid.NewString(), strings.ToLower(email), "Clerk User"); !errors.Is(err, ErrClerkEmailConflict) {
		t.Fatalf("Clerk email conflict error = %v", err)
	}
	var linked sql.NullString
	if err := db.GetContext(ctx, &linked, `SELECT clerk_id FROM users WHERE id = $1`, nativeID); err != nil {
		t.Fatal(err)
	}
	if linked.Valid {
		t.Fatalf("native account was linked to Clerk ID %#v", linked.String)
	}
}

func TestWebInvitationSwitchIsAtomicRecoverableAndRequiresOnboarding(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	oldUserID := insertPasskeyTestUser(t, db)
	oldSession, err := db.CreateFirstPartySession(ctx, oldUserID, "web", "Previous browser")
	if err != nil {
		t.Fatal(err)
	}
	invitation, token, err := db.CreateInvitation(ctx, uuid.NewString()+"@example.com", "New browser user")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = db.ExecContext(context.Background(), `DELETE FROM auth_invitations WHERE id = $1`, invitation.ID)
	})
	successor, _ := RandomFirstPartyRefreshToken()
	// The real onboarding route can see the access cookie (`/api/v1`), while
	// the refresh cookie is intentionally scoped to `/auth/web/session`.
	pair, err := db.RedeemWebInvitation(ctx, token, successor, []string{oldSession.AccessToken})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, pair.UserID) })
	if _, _, err := db.GetUserByFirstPartyAccessToken(ctx, oldSession.AccessToken); !errors.Is(err, ErrSessionInvalid) {
		t.Fatalf("previous session remained active: %v", err)
	}
	user, _, err := db.GetUserByFirstPartyAccessToken(ctx, pair.AccessToken)
	if err != nil || !user.OnboardingRequired {
		t.Fatalf("invited web user requirement = %#v, %v", user, err)
	}
	retried, err := db.RedeemWebInvitation(ctx, token, successor, []string{oldSession.AccessToken})
	if err != nil || retried.SessionID != pair.SessionID || retried.AccessToken == pair.AccessToken {
		t.Fatalf("lost response retry = %#v, %v", retried, err)
	}
}

func TestNativeInvitationDoesNotRequireWebOnlyCompletion(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	invitation, token, err := db.CreateInvitation(ctx, uuid.NewString()+"@example.com", "Native invited user")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = db.ExecContext(context.Background(), `DELETE FROM auth_invitations WHERE id = $1`, invitation.ID)
	})
	successor, _ := RandomFirstPartyRefreshToken()
	pair, err := db.RedeemInvitation(ctx, token, "ios", "iPhone", successor)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, pair.UserID) })
	user, _, err := db.GetUserByFirstPartyAccessToken(ctx, pair.AccessToken)
	if err != nil || user.OnboardingRequired {
		t.Fatalf("native invitation inherited web completion requirement: %#v, %v", user, err)
	}
}

func TestWebInvitationRevocationFailureRollsBackAccountAndLink(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	oldUserID := insertPasskeyTestUser(t, db)
	oldSession, err := db.CreateFirstPartySession(ctx, oldUserID, "web", "Previous browser")
	if err != nil {
		t.Fatal(err)
	}
	email := uuid.NewString() + "@example.com"
	invitation, token, err := db.CreateInvitation(ctx, email, "Rollback user")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = db.ExecContext(context.Background(), `DROP TRIGGER IF EXISTS fail_web_invite_revoke ON auth_sessions`)
		_, _ = db.ExecContext(context.Background(), `DROP FUNCTION IF EXISTS fail_web_invite_revoke_fn()`)
		_, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE email = $1`, email)
		_, _ = db.ExecContext(context.Background(), `DELETE FROM auth_invitations WHERE id = $1`, invitation.ID)
	})
	if _, err := db.ExecContext(ctx, `
		CREATE FUNCTION fail_web_invite_revoke_fn() RETURNS trigger AS $$
		BEGIN
			IF OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL THEN RAISE EXCEPTION 'injected revoke failure'; END IF;
			RETURN NEW;
		END; $$ LANGUAGE plpgsql`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `CREATE TRIGGER fail_web_invite_revoke BEFORE UPDATE ON auth_sessions FOR EACH ROW EXECUTE FUNCTION fail_web_invite_revoke_fn()`); err != nil {
		t.Fatal(err)
	}
	successor, _ := RandomFirstPartyRefreshToken()
	if _, err := db.RedeemWebInvitation(ctx, token, successor, []string{oldSession.AccessToken}); err == nil {
		t.Fatal("injected account-switch failure succeeded")
	}
	if user, _, err := db.GetUserByFirstPartyAccessToken(ctx, oldSession.AccessToken); err != nil || user.ID != oldUserID {
		t.Fatalf("rollback stranded previous account: %#v, %v", user, err)
	}
	var created, consumed int
	if err := db.GetContext(ctx, &created, `SELECT COUNT(*) FROM users WHERE email = $1`, email); err != nil {
		t.Fatal(err)
	}
	if err := db.GetContext(ctx, &consumed, `SELECT COUNT(*) FROM auth_invitations WHERE id = $1 AND consumed_at IS NOT NULL`, invitation.ID); err != nil {
		t.Fatal(err)
	}
	if created != 0 || consumed != 0 {
		t.Fatalf("rollback left new account=%d or consumed link=%d", created, consumed)
	}
	if _, err := db.ExecContext(ctx, `DROP TRIGGER fail_web_invite_revoke ON auth_sessions`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `DROP FUNCTION fail_web_invite_revoke_fn()`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.RedeemWebInvitation(ctx, token, successor, []string{oldSession.AccessToken}); err != nil {
		t.Fatalf("link not recoverable after rollback: %v", err)
	}
}
