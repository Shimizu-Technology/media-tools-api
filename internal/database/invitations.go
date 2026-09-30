package database

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

const InvitationTTL = 7 * 24 * time.Hour

var (
	ErrInvitationInvalid     = errors.New("invitation is invalid or already used")
	ErrInvitationEmailExists = errors.New("invitation email already has an account")
)

type AuthInvitation struct {
	ID        string    `json:"id" db:"id"`
	Email     string    `json:"email" db:"email"`
	Name      string    `json:"name" db:"name"`
	ExpiresAt time.Time `json:"expires_at" db:"expires_at"`
	CreatedAt time.Time `json:"created_at" db:"created_at"`
}

func normalizeInvitationEmail(email string) string {
	return strings.ToLower(strings.TrimSpace(email))
}

func invitationTokenHash(token string) (string, bool) {
	return authTokenHash(strings.TrimSpace(token), "mta_inv_")
}

func (db *DB) CreateInvitation(ctx context.Context, email, name string) (*AuthInvitation, string, error) {
	email = normalizeInvitationEmail(email)
	name = strings.TrimSpace(name)
	if email == "" || name == "" {
		return nil, "", fmt.Errorf("invitation email and name are required")
	}

	token, err := randomAuthToken("mta_inv_")
	if err != nil {
		return nil, "", err
	}
	tokenHash, _ := invitationTokenHash(token)
	now := time.Now().UTC()
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return nil, "", fmt.Errorf("begin invitation creation: %w", err)
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, email); err != nil {
		return nil, "", fmt.Errorf("lock invitation email: %w", err)
	}
	var existing int
	if err := tx.GetContext(ctx, &existing, `SELECT COUNT(*) FROM users WHERE lower(email) = lower($1)`, email); err != nil {
		return nil, "", fmt.Errorf("check invitation email: %w", err)
	}
	if existing > 0 {
		return nil, "", ErrInvitationEmailExists
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE auth_invitations SET revoked_at = $2
		WHERE lower(email) = lower($1) AND consumed_at IS NULL AND revoked_at IS NULL`, email, now); err != nil {
		return nil, "", fmt.Errorf("supersede invitation: %w", err)
	}
	invitation := &AuthInvitation{}
	if err := tx.GetContext(ctx, invitation, `
		INSERT INTO auth_invitations (email, name, token_hash, expires_at)
		VALUES ($1, $2, $3, $4)
		RETURNING id, email, name, expires_at, created_at`,
		email, name, tokenHash, now.Add(InvitationTTL)); err != nil {
		return nil, "", fmt.Errorf("create invitation: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return nil, "", fmt.Errorf("commit invitation creation: %w", err)
	}
	return invitation, token, nil
}

func (db *DB) RedeemInvitation(ctx context.Context, token, clientType, deviceName, nextRefreshToken string) (*AuthTokenPair, error) {
	hash, ok := invitationTokenHash(token)
	if !ok {
		return nil, ErrInvitationInvalid
	}
	if clientType != "web" && clientType != "ios" && clientType != "android" {
		return nil, fmt.Errorf("unsupported client type")
	}
	deviceName = strings.TrimSpace(deviceName)
	if len(deviceName) > 80 {
		return nil, fmt.Errorf("device name is too long")
	}
	successorHash, err := refreshSuccessorHash(nextRefreshToken)
	if err != nil {
		return nil, err
	}

	now := time.Now().UTC()
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("begin invitation redemption: %w", err)
	}
	defer tx.Rollback()
	var invitationEmail string
	err = tx.GetContext(ctx, &invitationEmail, `SELECT email FROM auth_invitations WHERE token_hash = $1`, hash)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrInvitationInvalid
	}
	if err != nil {
		return nil, fmt.Errorf("find invitation: %w", err)
	}
	// Creation and redemption use the same email-level lock before touching an
	// invitation row. That lets a replacement link and an older redemption race
	// without deadlocking or allowing both links to win.
	if _, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, normalizeInvitationEmail(invitationEmail)); err != nil {
		return nil, fmt.Errorf("lock invitation email: %w", err)
	}

	var invitation struct {
		ID         string         `db:"id"`
		Email      string         `db:"email"`
		Name       string         `db:"name"`
		ExpiresAt  time.Time      `db:"expires_at"`
		ConsumedAt sql.NullTime   `db:"consumed_at"`
		RevokedAt  sql.NullTime   `db:"revoked_at"`
		UserID     sql.NullString `db:"consumed_by_user_id"`
		SessionID  sql.NullString `db:"consumed_session_id"`
		Successor  sql.NullString `db:"successor_hash"`
	}
	err = tx.GetContext(ctx, &invitation, `
		SELECT id, email, name, expires_at, consumed_at, revoked_at,
		       consumed_by_user_id, consumed_session_id, successor_hash
		FROM auth_invitations
		WHERE token_hash = $1
		FOR UPDATE`, hash)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrInvitationInvalid
	}
	if err != nil {
		return nil, fmt.Errorf("load invitation: %w", err)
	}
	if invitation.ConsumedAt.Valid {
		if !invitation.UserID.Valid || !invitation.SessionID.Valid ||
			!invitation.Successor.Valid || invitation.Successor.String != successorHash {
			return nil, ErrInvitationInvalid
		}
		pair, err := recoverCredentialIssuanceTx(
			ctx, tx, invitation.SessionID.String, invitation.UserID.String,
			nextRefreshToken, invitation.ConsumedAt.Time, now,
		)
		if errors.Is(err, ErrSessionInvalid) {
			return nil, ErrInvitationInvalid
		}
		if err != nil {
			return nil, fmt.Errorf("recover invitation redemption: %w", err)
		}
		if err := tx.Commit(); err != nil {
			return nil, fmt.Errorf("commit recovered invitation redemption: %w", err)
		}
		return pair, nil
	}
	if invitation.RevokedAt.Valid {
		return nil, ErrInvitationInvalid
	}
	if !now.Before(invitation.ExpiresAt) {
		return nil, ErrInvitationInvalid
	}
	var existing int
	if err := tx.GetContext(ctx, &existing, `SELECT COUNT(*) FROM users WHERE lower(email) = lower($1)`, invitation.Email); err != nil {
		return nil, fmt.Errorf("check invitation account: %w", err)
	}
	if existing > 0 {
		return nil, ErrInvitationEmailExists
	}

	var userID string
	if err := tx.QueryRowContext(ctx, `
		INSERT INTO users (email, password_hash, name)
		VALUES ($1, '', $2)
		RETURNING id`, normalizeInvitationEmail(invitation.Email), invitation.Name).Scan(&userID); err != nil {
		return nil, fmt.Errorf("create invited user: %w", err)
	}
	pair, err := createFirstPartySessionWithRefreshTx(ctx, tx, userID, clientType, deviceName, nextRefreshToken, now)
	if errors.Is(err, errSuccessorUnavailable) {
		return nil, ErrInvitationInvalid
	}
	if err != nil {
		return nil, fmt.Errorf("create invited session: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE auth_invitations
		SET consumed_at = $2, consumed_by_user_id = $3,
		    consumed_session_id = $4, successor_hash = $5
		WHERE id = $1`, invitation.ID, now, userID, pair.SessionID, successorHash); err != nil {
		return nil, fmt.Errorf("consume invitation: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit invitation redemption: %w", err)
	}
	return pair, nil
}
