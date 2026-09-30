package database

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
)

func insertOnboardingRescueTestUser(t *testing.T, db *DB) string {
	t.Helper()
	var userID string
	if err := db.QueryRowContext(context.Background(), `
		INSERT INTO users (email, password_hash, name)
		VALUES ($1, '', 'Onboarding Rescue') RETURNING id`, uuid.NewString()+"@example.com").Scan(&userID); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, userID) })
	return userID
}

func TestOnboardingReissueSupersedesAndRecoversOneSession(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := insertOnboardingRescueTestUser(t, db)
	oldOne, err := db.CreateFirstPartySession(ctx, userID, "web", "Lost browser")
	if err != nil {
		t.Fatal(err)
	}
	oldTwo, err := db.CreateFirstPartySession(ctx, userID, "ios", "Lost phone")
	if err != nil {
		t.Fatal(err)
	}

	_, firstToken, err := db.CreateOnboardingReissue(ctx, userID)
	if err != nil {
		t.Fatal(err)
	}
	_, currentToken, err := db.CreateOnboardingReissue(ctx, userID)
	if err != nil {
		t.Fatal(err)
	}
	next, err := RandomFirstPartyRefreshToken()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.RedeemOnboardingReissue(ctx, firstToken, "ios", "New phone", next); !errors.Is(err, ErrOnboardingReissueInvalid) {
		t.Fatalf("superseded rescue redemption = %v", err)
	}

	type result struct {
		pair *AuthTokenPair
		err  error
	}
	results := make(chan result, 2)
	var workers sync.WaitGroup
	for range 2 {
		workers.Add(1)
		go func() {
			defer workers.Done()
			pair, err := db.RedeemOnboardingReissue(ctx, currentToken, "ios", "New phone", next)
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
		t.Fatalf("exact retry did not recover one session: %#v", pairs)
	}

	var revokedOld, activeNew int
	if err := db.GetContext(ctx, &revokedOld, `
		SELECT COUNT(*) FROM auth_sessions
		WHERE id IN ($1, $2) AND revoked_at IS NOT NULL`, oldOne.SessionID, oldTwo.SessionID); err != nil {
		t.Fatal(err)
	}
	if err := db.GetContext(ctx, &activeNew, `
		SELECT COUNT(*) FROM auth_sessions
		WHERE id = $1 AND revoked_at IS NULL`, pairs[0].SessionID); err != nil {
		t.Fatal(err)
	}
	if revokedOld != 2 || activeNew != 1 {
		t.Fatalf("session handoff = old revoked %d, new active %d", revokedOld, activeNew)
	}
	wrong, err := RandomFirstPartyRefreshToken()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.RedeemOnboardingReissue(ctx, currentToken, "ios", "New phone", wrong); !errors.Is(err, ErrOnboardingReissueInvalid) {
		t.Fatalf("wrong successor retry = %v", err)
	}
}

func TestOnboardingReissueRefusesAccountsWithRecoveryMethod(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := insertOnboardingRescueTestUser(t, db)
	_, token, err := db.CreateOnboardingReissue(ctx, userID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `
		INSERT INTO auth_recovery_codes (code_hash, user_id, active)
		VALUES ($1, $2, TRUE)`, recoveryCodeHash("MTR-test-"+uuid.NewString()), userID); err != nil {
		t.Fatal(err)
	}
	if _, _, err := db.CreateOnboardingReissue(ctx, userID); !errors.Is(err, ErrOnboardingReissueNotAllowed) {
		t.Fatalf("secured account reissue creation = %v", err)
	}
	next, err := RandomFirstPartyRefreshToken()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.RedeemOnboardingReissue(ctx, token, "android", "Phone", next); !errors.Is(err, ErrOnboardingReissueNotAllowed) {
		t.Fatalf("secured account reissue redemption = %v", err)
	}
	var sessions int
	if err := db.GetContext(ctx, &sessions, `SELECT COUNT(*) FROM auth_sessions WHERE user_id = $1`, userID); err != nil || sessions != 0 {
		t.Fatalf("secured rescue created sessions = %d, %v", sessions, err)
	}
}

func TestOnboardingReissueRejectsMalformedUserID(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	if _, _, err := db.CreateOnboardingReissue(context.Background(), "not-a-user-id"); !errors.Is(err, ErrOnboardingAccountNotFound) {
		t.Fatalf("malformed user ID = %v", err)
	}
}

func TestInvitationReplacementInvalidatesPriorUnusedLink(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	email := uuid.NewString() + "@example.com"
	first, firstToken, err := db.CreateInvitation(ctx, email, "First Name")
	if err != nil {
		t.Fatal(err)
	}
	second, secondToken, err := db.CreateInvitation(ctx, email, "Correct Name")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = db.ExecContext(context.Background(), `DELETE FROM auth_invitations WHERE id IN ($1, $2)`, first.ID, second.ID)
	})
	next, err := RandomFirstPartyRefreshToken()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.RedeemInvitation(ctx, firstToken, "ios", "Phone", next); !errors.Is(err, ErrInvitationInvalid) {
		t.Fatalf("superseded invitation redemption = %v", err)
	}
	pair, err := db.RedeemInvitation(ctx, secondToken, "ios", "Phone", next)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, pair.UserID) })
	var name string
	if err := db.GetContext(ctx, &name, `SELECT name FROM users WHERE id = $1`, pair.UserID); err != nil || name != "Correct Name" {
		t.Fatalf("replacement invitation user name = %q, %v", name, err)
	}
}

func TestInvitationReplacementAndRedemptionSerialize(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	for i := 0; i < 8; i++ {
		email := uuid.NewString() + "@example.com"
		first, token, err := db.CreateInvitation(context.Background(), email, "Original")
		if err != nil {
			t.Fatal(err)
		}
		next, err := RandomFirstPartyRefreshToken()
		if err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		start := make(chan struct{})
		type redeemResult struct {
			pair *AuthTokenPair
			err  error
		}
		type createResult struct {
			invitation *AuthInvitation
			err        error
		}
		redeemed := make(chan redeemResult, 1)
		created := make(chan createResult, 1)
		go func() {
			<-start
			pair, err := db.RedeemInvitation(ctx, token, "ios", "Phone", next)
			redeemed <- redeemResult{pair: pair, err: err}
		}()
		go func() {
			<-start
			invitation, _, err := db.CreateInvitation(ctx, email, "Replacement")
			created <- createResult{invitation: invitation, err: err}
		}()
		close(start)
		redeem := <-redeemed
		create := <-created
		cancel()

		switch {
		case redeem.err == nil && errors.Is(create.err, ErrInvitationEmailExists):
			_, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, redeem.pair.UserID)
		case errors.Is(redeem.err, ErrInvitationInvalid) && create.err == nil:
			_, _ = db.ExecContext(context.Background(), `DELETE FROM auth_invitations WHERE id = $1`, create.invitation.ID)
		default:
			t.Fatalf("race outcome %d: redeem pair=%#v err=%v, create=%#v err=%v", i, redeem.pair, redeem.err, create.invitation, create.err)
		}
		_, _ = db.ExecContext(context.Background(), `DELETE FROM auth_invitations WHERE id = $1`, first.ID)
		var users int
		if err := db.GetContext(context.Background(), &users, `SELECT COUNT(*) FROM users WHERE lower(email) = lower($1)`, email); err != nil || users != 0 {
			t.Fatalf("race cleanup %d left users=%d err=%v", i, users, err)
		}
	}
}
