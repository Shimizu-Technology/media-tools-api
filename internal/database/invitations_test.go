package database

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"sync"
	"testing"

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

	results := make(chan error, 2)
	var workers sync.WaitGroup
	for i := 0; i < 2; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			_, err := db.RedeemInvitation(ctx, token, "web", "Browser")
			results <- err
		}()
	}
	workers.Wait()
	close(results)
	var successes, rejections int
	for err := range results {
		if err == nil {
			successes++
		} else if errors.Is(err, ErrInvitationInvalid) {
			rejections++
		} else {
			t.Fatal(err)
		}
	}
	if successes != 1 || rejections != 1 {
		t.Fatalf("concurrent redemptions: success=%d rejected=%d", successes, rejections)
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
	if _, err := db.RedeemInvitation(ctx, token, "ios", "Phone"); !errors.Is(err, ErrInvitationInvalid) {
		t.Fatalf("expired invitation error = %v", err)
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
