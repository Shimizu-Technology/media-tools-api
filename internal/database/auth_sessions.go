package database

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

const (
	accessTokenLifetime   = 15 * time.Minute
	deviceInactivityLimit = 365 * 24 * time.Hour
	duplicateRefreshGrace = 15 * time.Second
)

var (
	ErrSessionInvalid        = errors.New("session credential is invalid or expired")
	ErrSessionAlreadyRotated = errors.New("session credential was just rotated")
	ErrSessionReplay         = errors.New("consumed session credential was replayed")
	ErrIdentityOwnedByOther  = errors.New("identity is linked to another user")
)

// EnsureAuthIdentity records a verified provider subject without ever moving
// an existing subject between users. Email addresses are not identity keys.
func (db *DB) EnsureAuthIdentity(ctx context.Context, userID, provider, subject string) error {
	if userID == "" || provider == "" || subject == "" {
		return fmt.Errorf("identity user, provider, and subject are required")
	}
	if _, err := db.ExecContext(ctx, `
		INSERT INTO auth_identities (user_id, provider, subject)
		VALUES ($1, $2, $3) ON CONFLICT (provider, subject) DO NOTHING`, userID, provider, subject); err != nil {
		return fmt.Errorf("record identity: %w", err)
	}
	var ownerID string
	if err := db.GetContext(ctx, &ownerID, `
		SELECT user_id FROM auth_identities WHERE provider = $1 AND subject = $2`, provider, subject); err != nil {
		return fmt.Errorf("verify identity owner: %w", err)
	}
	if ownerID != userID {
		return ErrIdentityOwnedByOther
	}
	return nil
}

// AuthTokenPair contains credentials returned once to the client. Only SHA-256
// hashes of the random bearer values are ever persisted in PostgreSQL.
type AuthTokenPair struct {
	SessionID         string    `json:"session_id"`
	UserID            string    `json:"user_id"`
	AccessToken       string    `json:"access_token"`
	AccessExpiresAt   time.Time `json:"access_expires_at"`
	RefreshToken      string    `json:"refresh_token"`
	InactiveExpiresAt time.Time `json:"inactive_expires_at"`
}

type AuthSession struct {
	ID                string     `json:"id" db:"id"`
	ClientType        string     `json:"client_type" db:"client_type"`
	DeviceName        string     `json:"device_name" db:"device_name"`
	CreatedAt         time.Time  `json:"created_at" db:"created_at"`
	LastUsedAt        time.Time  `json:"last_used_at" db:"last_used_at"`
	InactiveExpiresAt time.Time  `json:"inactive_expires_at" db:"inactive_expires_at"`
	RevokedAt         *time.Time `json:"revoked_at,omitempty" db:"revoked_at"`
}

func randomAuthToken(prefix string) (string, error) {
	bytes := make([]byte, 32)
	if _, err := rand.Read(bytes); err != nil {
		return "", fmt.Errorf("generate session credential: %w", err)
	}
	return prefix + base64.RawURLEncoding.EncodeToString(bytes), nil
}

func authTokenHash(token, prefix string) (string, bool) {
	if !strings.HasPrefix(token, prefix) {
		return "", false
	}
	bytes, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(token, prefix))
	if err != nil || len(bytes) != 32 || token != prefix+base64.RawURLEncoding.EncodeToString(bytes) {
		return "", false
	}
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:]), true
}

func newAuthTokenPair(now time.Time) (AuthTokenPair, string, string, error) {
	access, err := randomAuthToken("mta_at_")
	if err != nil {
		return AuthTokenPair{}, "", "", err
	}
	refresh, err := randomAuthToken("mta_rt_")
	if err != nil {
		return AuthTokenPair{}, "", "", err
	}
	accessHash, _ := authTokenHash(access, "mta_at_")
	refreshHash, _ := authTokenHash(refresh, "mta_rt_")
	return AuthTokenPair{
		AccessToken:       access,
		AccessExpiresAt:   now.Add(accessTokenLifetime),
		RefreshToken:      refresh,
		InactiveExpiresAt: now.Add(deviceInactivityLimit),
	}, accessHash, refreshHash, nil
}

// CreateFirstPartySession issues one revocable session for a verified user.
// Caller authentication is deliberately separate from token issuance.
func (db *DB) CreateFirstPartySession(ctx context.Context, userID, clientType, deviceName string) (*AuthTokenPair, error) {
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
		return nil, fmt.Errorf("begin session creation: %w", err)
	}
	defer tx.Rollback()
	if err := tx.QueryRowContext(ctx, `
		INSERT INTO auth_sessions (user_id, client_type, device_name, last_used_at, inactive_expires_at)
		VALUES ($1, $2, $3, $4, $5) RETURNING id`,
		userID, clientType, deviceName, now, pair.InactiveExpiresAt).Scan(&pair.SessionID); err != nil {
		return nil, fmt.Errorf("create session: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO auth_access_tokens (token_hash, session_id, expires_at) VALUES ($1, $2, $3)`,
		accessHash, pair.SessionID, pair.AccessExpiresAt); err != nil {
		return nil, fmt.Errorf("save access credential: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO auth_refresh_tokens (token_hash, session_id, expires_at) VALUES ($1, $2, $3)`,
		refreshHash, pair.SessionID, pair.InactiveExpiresAt); err != nil {
		return nil, fmt.Errorf("save refresh credential: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit session creation: %w", err)
	}
	pair.UserID = userID
	return &pair, nil
}

// RefreshFirstPartySession consumes a refresh credential exactly once. A very
// recent duplicate receives a retryable conflict so concurrent client calls do
// not revoke their own session; an older replay revokes the entire device.
func (db *DB) RefreshFirstPartySession(ctx context.Context, credential string) (*AuthTokenPair, error) {
	hash, ok := authTokenHash(credential, "mta_rt_")
	if !ok {
		return nil, ErrSessionInvalid
	}
	now := time.Now().UTC()
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("begin session refresh: %w", err)
	}
	defer tx.Rollback()
	var row struct {
		SessionID         string       `db:"session_id"`
		UserID            string       `db:"user_id"`
		TokenExpiresAt    time.Time    `db:"token_expires_at"`
		ConsumedAt        sql.NullTime `db:"consumed_at"`
		InactiveExpiresAt time.Time    `db:"inactive_expires_at"`
		RevokedAt         sql.NullTime `db:"revoked_at"`
	}
	err = tx.GetContext(ctx, &row, `
		SELECT t.session_id, s.user_id, t.expires_at AS token_expires_at,
		       t.consumed_at, s.inactive_expires_at, s.revoked_at
		FROM auth_refresh_tokens t JOIN auth_sessions s ON s.id = t.session_id
		WHERE t.token_hash = $1 FOR UPDATE OF t, s`, hash)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrSessionInvalid
	}
	if err != nil {
		return nil, fmt.Errorf("load session refresh credential: %w", err)
	}
	if row.RevokedAt.Valid || !now.Before(row.TokenExpiresAt) || !now.Before(row.InactiveExpiresAt) {
		return nil, ErrSessionInvalid
	}
	if row.ConsumedAt.Valid {
		if now.Sub(row.ConsumedAt.Time) <= duplicateRefreshGrace {
			return nil, ErrSessionAlreadyRotated
		}
		if _, err := tx.ExecContext(ctx, `UPDATE auth_sessions SET revoked_at = $2 WHERE id = $1`, row.SessionID, now); err != nil {
			return nil, fmt.Errorf("revoke replayed session: %w", err)
		}
		if err := tx.Commit(); err != nil {
			return nil, fmt.Errorf("commit replay revocation: %w", err)
		}
		return nil, ErrSessionReplay
	}
	pair, accessHash, refreshHash, err := newAuthTokenPair(now)
	if err != nil {
		return nil, err
	}
	pair.SessionID = row.SessionID
	pair.UserID = row.UserID
	if _, err := tx.ExecContext(ctx, `UPDATE auth_refresh_tokens SET consumed_at = $2 WHERE token_hash = $1`, hash, now); err != nil {
		return nil, fmt.Errorf("consume refresh credential: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `UPDATE auth_sessions SET last_used_at = $2, inactive_expires_at = $3 WHERE id = $1`, row.SessionID, now, pair.InactiveExpiresAt); err != nil {
		return nil, fmt.Errorf("extend session inactivity: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO auth_access_tokens (token_hash, session_id, expires_at) VALUES ($1, $2, $3)`, accessHash, row.SessionID, pair.AccessExpiresAt); err != nil {
		return nil, fmt.Errorf("save rotated access credential: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO auth_refresh_tokens (token_hash, session_id, expires_at) VALUES ($1, $2, $3)`, refreshHash, row.SessionID, pair.InactiveExpiresAt); err != nil {
		return nil, fmt.Errorf("save rotated refresh credential: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit session refresh: %w", err)
	}
	return &pair, nil
}

func (db *DB) GetUserByFirstPartyAccessToken(ctx context.Context, credential string) (*models.User, string, error) {
	hash, ok := authTokenHash(credential, "mta_at_")
	if !ok {
		return nil, "", ErrSessionInvalid
	}
	var row struct {
		models.User
		SessionID string `db:"session_id"`
	}
	err := db.GetContext(ctx, &row, `
		SELECT u.*, s.id AS session_id FROM auth_access_tokens t
		JOIN auth_sessions s ON s.id = t.session_id
		JOIN users u ON u.id = s.user_id
		WHERE t.token_hash = $1 AND t.expires_at > NOW()
		  AND s.inactive_expires_at > NOW() AND s.revoked_at IS NULL`, hash)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, "", ErrSessionInvalid
	}
	if err != nil {
		return nil, "", fmt.Errorf("load access credential: %w", err)
	}
	return &row.User, row.SessionID, nil
}

func (db *DB) ListFirstPartySessions(ctx context.Context, userID string) ([]AuthSession, error) {
	var sessions []AuthSession
	err := db.SelectContext(ctx, &sessions, `
		SELECT id, client_type, device_name, created_at, last_used_at,
		       inactive_expires_at, revoked_at
		FROM auth_sessions WHERE user_id = $1 ORDER BY created_at DESC`, userID)
	if err != nil {
		return nil, fmt.Errorf("list device sessions: %w", err)
	}
	return sessions, nil
}

func (db *DB) RevokeFirstPartySession(ctx context.Context, userID, sessionID string) (bool, error) {
	result, err := db.ExecContext(ctx, `
		UPDATE auth_sessions SET revoked_at = COALESCE(revoked_at, NOW())
		WHERE id = $1 AND user_id = $2`, sessionID, userID)
	if err != nil {
		return false, fmt.Errorf("revoke device session: %w", err)
	}
	count, err := result.RowsAffected()
	return count > 0, err
}
