package database

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

var ErrClerkDetachmentNotReady = errors.New("account needs a passkey and an unused recovery code before Clerk can be detached")

// ClerkDetachmentReadiness describes whether Clerk is still linked and which
// first-party recovery factors make it safe to remove that link.
type ClerkDetachmentReadiness struct {
	Linked              bool `json:"linked"`
	Ready               bool `json:"ready"`
	PasskeyCount        int  `json:"passkey_count"`
	UnusedRecoveryCodes int  `json:"unused_recovery_codes"`
}

func clerkDetachmentReadinessTx(ctx context.Context, tx *sql.Tx, userID string) (*ClerkDetachmentReadiness, error) {
	var status ClerkDetachmentReadiness
	var clerkID sql.NullString
	if err := tx.QueryRowContext(ctx, `SELECT clerk_id FROM users WHERE id = $1 FOR UPDATE`, userID).Scan(&clerkID); err != nil {
		return nil, fmt.Errorf("lock account for Clerk detachment: %w", err)
	}
	if err := tx.QueryRowContext(ctx, `
		SELECT
			EXISTS (SELECT 1 FROM auth_identities WHERE user_id = $1 AND provider = 'clerk'),
			(SELECT COUNT(*) FROM auth_passkey_credentials WHERE user_id = $1),
			(SELECT COUNT(*) FROM auth_recovery_codes WHERE user_id = $1 AND active AND consumed_at IS NULL)`, userID).
		Scan(&status.Linked, &status.PasskeyCount, &status.UnusedRecoveryCodes); err != nil {
		return nil, fmt.Errorf("check Clerk detachment factors: %w", err)
	}
	status.Linked = status.Linked || (clerkID.Valid && clerkID.String != "")
	status.Ready = !status.Linked || (status.PasskeyCount > 0 && status.UnusedRecoveryCodes > 0)
	return &status, nil
}

// GetClerkDetachmentReadiness returns a transactionally consistent snapshot.
// The same account lock is used by DetachClerkIdentity and recovery-code
// rotation/redemption, so the operation cannot race a code becoming active or
// consumed while it decides whether the account remains recoverable.
func (db *DB) GetClerkDetachmentReadiness(ctx context.Context, userID string) (*ClerkDetachmentReadiness, error) {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("begin Clerk detachment readiness: %w", err)
	}
	defer tx.Rollback()
	status, err := clerkDetachmentReadinessTx(ctx, tx, userID)
	if err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit Clerk detachment readiness: %w", err)
	}
	return status, nil
}

// DetachClerkIdentity removes only the provider link after first-party recovery
// is ready. The stable user, content, API keys, and device sessions are kept.
// Repeating the operation after a successful detach is an idempotent success.
func (db *DB) DetachClerkIdentity(ctx context.Context, userID string) (*ClerkDetachmentReadiness, error) {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("begin Clerk detachment: %w", err)
	}
	defer tx.Rollback()
	status, err := clerkDetachmentReadinessTx(ctx, tx, userID)
	if err != nil {
		return nil, err
	}
	if !status.Ready {
		return status, ErrClerkDetachmentNotReady
	}
	if status.Linked {
		if _, err := tx.ExecContext(ctx, `UPDATE users SET clerk_id = NULL WHERE id = $1`, userID); err != nil {
			return nil, fmt.Errorf("clear legacy Clerk user ID: %w", err)
		}
		if _, err := tx.ExecContext(ctx, `DELETE FROM auth_identities WHERE user_id = $1 AND provider = 'clerk'`, userID); err != nil {
			return nil, fmt.Errorf("remove Clerk identity: %w", err)
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit Clerk detachment: %w", err)
	}
	status.Linked = false
	status.Ready = true
	return status, nil
}
