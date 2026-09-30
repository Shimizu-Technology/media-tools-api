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

	var existing int
	if err := db.GetContext(ctx, &existing, `SELECT COUNT(*) FROM users WHERE lower(email) = lower($1)`, email); err != nil {
		return nil, "", fmt.Errorf("check invitation email: %w", err)
	}
	if existing > 0 {
		return nil, "", ErrInvitationEmailExists
	}

	token, err := randomAuthToken("mta_inv_")
	if err != nil {
		return nil, "", err
	}
	tokenHash, _ := invitationTokenHash(token)
	invitation := &AuthInvitation{}
	if err := db.GetContext(ctx, invitation, `
		INSERT INTO auth_invitations (email, name, token_hash, expires_at)
		VALUES ($1, $2, $3, $4)
		RETURNING id, email, name, expires_at, created_at`,
		email, name, tokenHash, time.Now().UTC().Add(InvitationTTL)); err != nil {
		return nil, "", fmt.Errorf("create invitation: %w", err)
	}
	return invitation, token, nil
}

func (db *DB) RedeemInvitation(ctx context.Context, token, clientType, deviceName string) (*AuthTokenPair, error) {
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

	now := time.Now().UTC()
	pair, accessHash, refreshHash, err := newAuthTokenPair(now)
	if err != nil {
		return nil, err
	}
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("begin invitation redemption: %w", err)
	}
	defer tx.Rollback()

	var invitation struct {
		ID         string       `db:"id"`
		Email      string       `db:"email"`
		Name       string       `db:"name"`
		ExpiresAt  time.Time    `db:"expires_at"`
		ConsumedAt sql.NullTime `db:"consumed_at"`
	}
	err = tx.GetContext(ctx, &invitation, `
		SELECT id, email, name, expires_at, consumed_at
		FROM auth_invitations
		WHERE token_hash = $1
		FOR UPDATE`, hash)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrInvitationInvalid
	}
	if err != nil {
		return nil, fmt.Errorf("load invitation: %w", err)
	}
	if invitation.ConsumedAt.Valid || !now.Before(invitation.ExpiresAt) {
		return nil, ErrInvitationInvalid
	}
	if _, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, normalizeInvitationEmail(invitation.Email)); err != nil {
		return nil, fmt.Errorf("lock invitation email: %w", err)
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
	if err := tx.QueryRowContext(ctx, `
		INSERT INTO auth_sessions (user_id, client_type, device_name, last_used_at, inactive_expires_at)
		VALUES ($1, $2, $3, $4, $5)
		RETURNING id`,
		userID, clientType, deviceName, now, pair.InactiveExpiresAt).Scan(&pair.SessionID); err != nil {
		return nil, fmt.Errorf("create invited session: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO auth_access_tokens (token_hash, session_id, expires_at)
		VALUES ($1, $2, $3)`, accessHash, pair.SessionID, pair.AccessExpiresAt); err != nil {
		return nil, fmt.Errorf("save invitation access credential: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO auth_refresh_tokens (token_hash, session_id, expires_at)
		VALUES ($1, $2, $3)`, refreshHash, pair.SessionID, pair.InactiveExpiresAt); err != nil {
		return nil, fmt.Errorf("save invitation refresh credential: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE auth_invitations
		SET consumed_at = $2, consumed_by_user_id = $3
		WHERE id = $1`, invitation.ID, now, userID); err != nil {
		return nil, fmt.Errorf("consume invitation: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit invitation redemption: %w", err)
	}
	pair.UserID = userID
	return &pair, nil
}
