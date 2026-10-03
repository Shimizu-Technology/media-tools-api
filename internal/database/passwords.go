package database

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"golang.org/x/text/unicode/norm"
)

const (
	passwordFailureWindow = 15 * time.Minute
	passwordFailureLimit  = 10
	passwordLockDuration  = 15 * time.Minute
)

var (
	ErrPasswordCredentialInvalid = errors.New("password credential is invalid")
	ErrPasswordCredentialChanged = errors.New("password credential changed")
	ErrPasswordCredentialLocked  = errors.New("password credential is temporarily locked")
)

type PasswordCredential struct {
	UserID                 string     `db:"user_id"`
	EmailNormalized        string     `db:"email_normalized"`
	PasswordHash           string     `db:"password_hash"`
	FailedAttempts         int        `db:"failed_attempts"`
	FailureWindowStartedAt *time.Time `db:"failure_window_started_at"`
	LockedUntil            *time.Time `db:"locked_until"`
	UpdatedAt              time.Time  `db:"updated_at"`
}

type PasswordStatus struct {
	Configured bool       `json:"configured"`
	UpdatedAt  *time.Time `json:"updated_at,omitempty"`
}

func NormalizeLoginEmail(email string) string {
	return strings.ToLower(norm.NFC.String(strings.TrimSpace(email)))
}

func (db *DB) GetPasswordCredentialByEmail(ctx context.Context, email string) (*PasswordCredential, error) {
	var credential PasswordCredential
	err := db.GetContext(ctx, &credential, `
		SELECT user_id, email_normalized, password_hash, failed_attempts,
		       failure_window_started_at, locked_until, updated_at
		FROM auth_password_credentials WHERE email_normalized = $1`, NormalizeLoginEmail(email))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrPasswordCredentialInvalid
	}
	if err != nil {
		return nil, fmt.Errorf("load password credential: %w", err)
	}
	return &credential, nil
}

func (db *DB) GetPasswordStatus(ctx context.Context, userID string) (*PasswordStatus, error) {
	var updated time.Time
	err := db.GetContext(ctx, &updated, `SELECT updated_at FROM auth_password_credentials WHERE user_id = $1`, userID)
	if errors.Is(err, sql.ErrNoRows) {
		return &PasswordStatus{}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("load password status: %w", err)
	}
	return &PasswordStatus{Configured: true, UpdatedAt: &updated}, nil
}

// RecordPasswordFailure updates only the exact credential version the handler
// verified. A concurrent password change therefore cannot inherit failures
// from an attempt made against its previous hash.
func (db *DB) RecordPasswordFailure(ctx context.Context, userID, hashSnapshot string) error {
	now := time.Now().UTC()
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin password failure: %w", err)
	}
	defer tx.Rollback()
	var row PasswordCredential
	err = tx.GetContext(ctx, &row, `
		SELECT user_id, email_normalized, password_hash, failed_attempts,
		       failure_window_started_at, locked_until, updated_at
		FROM auth_password_credentials WHERE user_id = $1 FOR UPDATE`, userID)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && row.PasswordHash != hashSnapshot) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("lock password failure: %w", err)
	}
	attempts := row.FailedAttempts + 1
	window := now
	if row.FailureWindowStartedAt != nil && now.Sub(*row.FailureWindowStartedAt) < passwordFailureWindow {
		window = *row.FailureWindowStartedAt
	} else {
		attempts = 1
	}
	var lockedUntil any
	if attempts >= passwordFailureLimit {
		lockedUntil = now.Add(passwordLockDuration)
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE auth_password_credentials
		SET failed_attempts = $2, failure_window_started_at = $3,
		    locked_until = $4, updated_at = $5
		WHERE user_id = $1`, userID, attempts, window, lockedUntil, now); err != nil {
		return fmt.Errorf("record password failure: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit password failure: %w", err)
	}
	return nil
}

// CreateOrRecoverPasswordSession rechecks the exact hash under lock before
// issuing a durable session. This prevents an old password that verified just
// before a concurrent password replacement from creating a surviving session.
func (db *DB) CreateOrRecoverPasswordSession(ctx context.Context, userID, hashSnapshot, replacementHash, clientType, deviceName, nextRefreshToken string) (*AuthTokenPair, error) {
	return db.createOrRecoverPasswordSession(ctx, userID, hashSnapshot, replacementHash, clientType, deviceName, nextRefreshToken, nil)
}

// CreateOrRecoverWebPasswordSession changes browser accounts atomically. The
// old cookie-backed session remains valid until the password is accepted and
// the replacement session has been created. Exact retries keep the recovered
// session while revoking only credentials that were already in the browser.
func (db *DB) CreateOrRecoverWebPasswordSession(ctx context.Context, userID, hashSnapshot, replacementHash, nextRefreshToken string, existingCredentials []string) (*AuthTokenPair, error) {
	return db.createOrRecoverPasswordSession(ctx, userID, hashSnapshot, replacementHash, "web", "Browser", nextRefreshToken, existingCredentials)
}

func (db *DB) createOrRecoverPasswordSession(ctx context.Context, userID, hashSnapshot, replacementHash, clientType, deviceName, nextRefreshToken string, existingCredentials []string) (*AuthTokenPair, error) {
	deviceName, successorHash, err := validateRecoverableSessionInput(clientType, deviceName, nextRefreshToken)
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("begin password session: %w", err)
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, successorHash); err != nil {
		return nil, fmt.Errorf("lock password session successor: %w", err)
	}
	var row PasswordCredential
	err = tx.GetContext(ctx, &row, `
		SELECT user_id, email_normalized, password_hash, failed_attempts,
		       failure_window_started_at, locked_until, updated_at
		FROM auth_password_credentials WHERE user_id = $1 FOR UPDATE`, userID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrPasswordCredentialInvalid
	}
	if err != nil {
		return nil, fmt.Errorf("lock password credential: %w", err)
	}
	if row.PasswordHash != hashSnapshot {
		return nil, ErrPasswordCredentialChanged
	}
	if row.LockedUntil != nil && now.Before(*row.LockedUntil) {
		return nil, ErrPasswordCredentialLocked
	}
	if replacementHash != "" {
		if _, err := tx.ExecContext(ctx, `
			UPDATE auth_password_credentials SET password_hash = $2, updated_at = $3
			WHERE user_id = $1`, userID, replacementHash, now); err != nil {
			return nil, fmt.Errorf("upgrade password credential: %w", err)
		}
	}
	pair, commitOnError, err := createOrRecoverFirstPartySessionTx(ctx, tx, userID, clientType, deviceName, nextRefreshToken, successorHash, now, false)
	if err != nil {
		if commitOnError {
			if commitErr := tx.Commit(); commitErr != nil {
				return nil, fmt.Errorf("commit invalid password session: %w", commitErr)
			}
		}
		return nil, err
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE auth_password_credentials
		SET failed_attempts = 0, failure_window_started_at = NULL,
		    locked_until = NULL, updated_at = GREATEST(updated_at, $2)
		WHERE user_id = $1`, userID, now); err != nil {
		return nil, fmt.Errorf("clear password failures: %w", err)
	}
	if err := revokeBrowserSessionsByCredentialTx(ctx, tx, existingCredentials, pair.SessionID, now); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit password session: %w", err)
	}
	return pair, nil
}

// SetPasswordCredential trusts the same first-party session boundary already
// used to add passkeys and rotate recovery codes. Replacing a password revokes
// every other device so a compromised old session cannot survive the change.
func (db *DB) SetPasswordCredential(ctx context.Context, userID, currentSessionID, encodedHash string) (*PasswordStatus, error) {
	if userID == "" || currentSessionID == "" || encodedHash == "" {
		return nil, ErrPasswordCredentialInvalid
	}
	now := time.Now().UTC()
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("begin set password: %w", err)
	}
	defer tx.Rollback()
	var email string
	if err := tx.GetContext(ctx, &email, `SELECT email FROM users WHERE id = $1 FOR UPDATE`, userID); err != nil {
		return nil, fmt.Errorf("lock password account: %w", err)
	}
	var sessionValid bool
	if err := tx.GetContext(ctx, &sessionValid, `
		SELECT EXISTS (
			SELECT 1 FROM auth_sessions
			WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL AND inactive_expires_at > $3
		)`, currentSessionID, userID, now); err != nil {
		return nil, fmt.Errorf("verify password session: %w", err)
	}
	if !sessionValid {
		return nil, ErrSessionInvalid
	}
	var existed bool
	if err := tx.GetContext(ctx, &existed, `SELECT EXISTS (SELECT 1 FROM auth_password_credentials WHERE user_id = $1)`, userID); err != nil {
		return nil, fmt.Errorf("check password credential: %w", err)
	}
	normalizedEmail := NormalizeLoginEmail(email)
	if normalizedEmail == "" {
		return nil, ErrPasswordCredentialInvalid
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO auth_password_credentials
			(user_id, email_normalized, password_hash, failed_attempts, failure_window_started_at, locked_until, created_at, updated_at)
		VALUES ($1, $2, $3, 0, NULL, NULL, $4, $4)
		ON CONFLICT (user_id) DO UPDATE SET
			email_normalized = EXCLUDED.email_normalized,
			password_hash = EXCLUDED.password_hash,
			failed_attempts = 0,
			failure_window_started_at = NULL,
			locked_until = NULL,
			updated_at = EXCLUDED.updated_at`, userID, normalizedEmail, encodedHash, now); err != nil {
		return nil, fmt.Errorf("save password credential: %w", err)
	}
	// A stale bcrypt value must never become usable if the legacy development
	// routes are accidentally enabled after first-party enrollment.
	if _, err := tx.ExecContext(ctx, `UPDATE users SET password_hash = '' WHERE id = $1`, userID); err != nil {
		return nil, fmt.Errorf("clear legacy password: %w", err)
	}
	if existed {
		if _, err := tx.ExecContext(ctx, `
			UPDATE auth_sessions SET revoked_at = COALESCE(revoked_at, $3)
			WHERE user_id = $1 AND id <> $2 AND revoked_at IS NULL`, userID, currentSessionID, now); err != nil {
			return nil, fmt.Errorf("revoke other password sessions: %w", err)
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit set password: %w", err)
	}
	return &PasswordStatus{Configured: true, UpdatedAt: &now}, nil
}
