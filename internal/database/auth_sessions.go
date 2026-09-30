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

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jmoiron/sqlx"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
)

const (
	accessTokenLifetime   = 15 * time.Minute
	deviceInactivityLimit = 365 * 24 * time.Hour
	duplicateRefreshGrace = 15 * time.Second
	// credentialIssuanceRetryWindow lets a mobile client recover after an app
	// crash or a long background interval, while still bounding how long a
	// spent invitation or recovery code can be paired with its saved successor.
	credentialIssuanceRetryWindow = 24 * time.Hour
)

var (
	ErrSessionInvalid        = errors.New("session credential is invalid or expired")
	ErrSessionAlreadyRotated = errors.New("session credential was just rotated")
	ErrSessionReplay         = errors.New("consumed session credential was replayed")
	ErrInvalidSuccessorToken = errors.New("next refresh credential is invalid")
	ErrIdentityOwnedByOther  = errors.New("identity is linked to another user")
	errSuccessorUnavailable  = errors.New("next refresh credential is unavailable")
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

// RandomFirstPartyRefreshToken gives clients a well-formed random successor
// for recoverable refresh. The client must persist it before sending a request.
func RandomFirstPartyRefreshToken() (string, error) {
	return randomAuthToken("mta_rt_")
}

// ValidFirstPartyRefreshToken checks the canonical shape before a one-use
// ceremony is consumed. It does not query token ownership or session state.
func ValidFirstPartyRefreshToken(token string) bool {
	_, ok := authTokenHash(token, "mta_rt_")
	return ok
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

func newAuthTokenPairWithRefresh(now time.Time, refresh string) (AuthTokenPair, string, string, error) {
	refreshHash, ok := authTokenHash(refresh, "mta_rt_")
	if !ok {
		return AuthTokenPair{}, "", "", ErrSessionInvalid
	}
	access, err := randomAuthToken("mta_at_")
	if err != nil {
		return AuthTokenPair{}, "", "", err
	}
	accessHash, _ := authTokenHash(access, "mta_at_")
	return AuthTokenPair{
		AccessToken:       access,
		AccessExpiresAt:   now.Add(accessTokenLifetime),
		RefreshToken:      refresh,
		InactiveExpiresAt: now.Add(deviceInactivityLimit),
	}, accessHash, refreshHash, nil
}

func refreshSuccessorHash(successor string) (string, error) {
	hash, ok := authTokenHash(successor, "mta_rt_")
	if !ok {
		return "", ErrInvalidSuccessorToken
	}
	return hash, nil
}

func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}

// createFirstPartySessionWithRefreshTx creates a session using a refresh
// credential that the client has already saved. The caller owns the
// transaction so account creation, one-time credential consumption, and
// session issuance can commit together.
func createFirstPartySessionWithRefreshTx(ctx context.Context, tx *sqlx.Tx, userID, clientType, deviceName, refresh string, now time.Time) (*AuthTokenPair, error) {
	pair, accessHash, refreshHash, err := newAuthTokenPairWithRefresh(now, refresh)
	if err != nil {
		return nil, err
	}
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
		if isUniqueViolation(err) {
			return nil, errSuccessorUnavailable
		}
		return nil, fmt.Errorf("save refresh credential: %w", err)
	}
	pair.UserID = userID
	return &pair, nil
}

// recoverCredentialIssuanceTx mints only a fresh short-lived access token for
// an exact, recent retry. The persisted client refresh credential and session
// stay unchanged, so callers can safely retry after losing the first response.
func recoverCredentialIssuanceTx(ctx context.Context, tx *sqlx.Tx, sessionID, userID, successor string, consumedAt, now time.Time) (*AuthTokenPair, error) {
	if consumedAt.IsZero() || !now.Before(consumedAt.Add(credentialIssuanceRetryWindow)) {
		return nil, ErrSessionInvalid
	}
	return recoverSessionWithSuccessorTx(ctx, tx, sessionID, userID, successor, now)
}

// recoverSessionWithSuccessorTx mints a fresh short-lived access token only
// while the exact successor still belongs to an active, refreshable session.
// Callers separately enforce any ceremony-specific retry window.
func recoverSessionWithSuccessorTx(ctx context.Context, tx *sqlx.Tx, sessionID, userID, successor string, now time.Time) (*AuthTokenPair, error) {
	successorHash, err := refreshSuccessorHash(successor)
	if err != nil {
		return nil, ErrSessionInvalid
	}
	var row struct {
		InactiveExpiresAt time.Time    `db:"inactive_expires_at"`
		RevokedAt         sql.NullTime `db:"revoked_at"`
		RefreshExpiresAt  time.Time    `db:"refresh_expires_at"`
		RefreshConsumedAt sql.NullTime `db:"refresh_consumed_at"`
	}
	err = tx.GetContext(ctx, &row, `
		SELECT s.inactive_expires_at, s.revoked_at,
		       r.expires_at AS refresh_expires_at, r.consumed_at AS refresh_consumed_at
		FROM auth_sessions s
		JOIN auth_refresh_tokens r ON r.session_id = s.id AND r.token_hash = $3
		WHERE s.id = $1 AND s.user_id = $2
		FOR UPDATE OF s, r`, sessionID, userID, successorHash)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrSessionInvalid
	}
	if err != nil {
		return nil, fmt.Errorf("load redeemed session: %w", err)
	}
	if row.RevokedAt.Valid || row.RefreshConsumedAt.Valid ||
		!now.Before(row.InactiveExpiresAt) || !now.Before(row.RefreshExpiresAt) {
		return nil, ErrSessionInvalid
	}
	pair, accessHash, _, err := newAuthTokenPairWithRefresh(now, successor)
	if err != nil {
		return nil, err
	}
	pair.SessionID = sessionID
	pair.UserID = userID
	pair.InactiveExpiresAt = row.InactiveExpiresAt
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO auth_access_tokens (token_hash, session_id, expires_at) VALUES ($1, $2, $3)`,
		accessHash, sessionID, pair.AccessExpiresAt); err != nil {
		return nil, fmt.Errorf("save recovered access credential: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `UPDATE auth_sessions SET last_used_at = $2 WHERE id = $1`, sessionID, now); err != nil {
		return nil, fmt.Errorf("touch recovered session: %w", err)
	}
	return &pair, nil
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

// CreateOrRecoverFirstPartySession issues a session with a refresh credential
// the client durably saved before sending its request. An exact retry while
// that session and refresh credential remain active receives a fresh access
// token for the original session instead of creating another long-lived
// session. Session and refresh expiry bound the recovery lifetime.
//
// The database method accepts web because the same-origin cookie handler owns
// and preinstalls that successor. Raw HTTP handlers must reject web callers so
// refresh credentials are never returned to browser JavaScript.
func (db *DB) CreateOrRecoverFirstPartySession(ctx context.Context, userID, clientType, deviceName, nextRefreshToken string) (*AuthTokenPair, error) {
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
		return nil, fmt.Errorf("begin recoverable session creation: %w", err)
	}
	defer tx.Rollback()

	// Serialize one successor without locking the account or unrelated device
	// bootstrap requests. The table's primary key remains the final safeguard.
	if _, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, successorHash); err != nil {
		return nil, fmt.Errorf("lock session successor: %w", err)
	}
	// An exact saved successor is the refresh credential itself, so a native
	// bootstrap remains recoverable for the session's full active lifetime.
	// Prune only links that can no longer recover a valid session.
	if _, err := tx.ExecContext(ctx, `
		DELETE FROM auth_session_bootstrap_issuances i
		USING auth_sessions s, auth_refresh_tokens r
		WHERE i.user_id = $3
		  AND i.successor_hash <> $2
		  AND i.session_id = s.id
		  AND r.session_id = s.id AND r.token_hash = i.successor_hash
		  AND (s.revoked_at IS NOT NULL OR s.inactive_expires_at <= $1
		       OR r.consumed_at IS NOT NULL OR r.expires_at <= $1)`, now, successorHash, userID); err != nil {
		return nil, fmt.Errorf("prune session bootstrap issuances: %w", err)
	}

	var issuance struct {
		SessionID  string `db:"session_id"`
		UserID     string `db:"user_id"`
		ClientType string `db:"client_type"`
	}
	err = tx.GetContext(ctx, &issuance, `
		SELECT session_id, user_id, client_type
		FROM auth_session_bootstrap_issuances
		WHERE successor_hash = $1
		FOR UPDATE`, successorHash)
	switch {
	case err == nil:
		if issuance.UserID != userID || issuance.ClientType != clientType {
			return nil, ErrSessionInvalid
		}
		pair, recoverErr := recoverSessionWithSuccessorTx(
			ctx, tx, issuance.SessionID, issuance.UserID,
			nextRefreshToken, now,
		)
		if errors.Is(recoverErr, ErrSessionInvalid) {
			// Keep the hash as a tombstone for this exact successor. A later
			// bootstrap prunes it once the matching invalid refresh row is
			// visible, but a temporarily missing refresh row cannot turn a used
			// client credential back into a new-session credential.
			if err := tx.Commit(); err != nil {
				return nil, fmt.Errorf("commit invalid session bootstrap: %w", err)
			}
			return nil, ErrSessionInvalid
		}
		if recoverErr != nil {
			return nil, fmt.Errorf("recover session bootstrap: %w", recoverErr)
		}
		if err := tx.Commit(); err != nil {
			return nil, fmt.Errorf("commit recovered session bootstrap: %w", err)
		}
		return pair, nil
	case !errors.Is(err, sql.ErrNoRows):
		return nil, fmt.Errorf("load session bootstrap issuance: %w", err)
	}
	// A successor may already belong to a session created by another ceremony.
	// Detect it before attempting inserts so pruning can still commit and the
	// failed bootstrap never creates even transaction-local session rows.
	var successorExists bool
	if err := tx.GetContext(ctx, &successorExists, `SELECT EXISTS (SELECT 1 FROM auth_refresh_tokens WHERE token_hash = $1)`, successorHash); err != nil {
		return nil, fmt.Errorf("check session successor availability: %w", err)
	}
	if successorExists {
		if err := tx.Commit(); err != nil {
			return nil, fmt.Errorf("commit session bootstrap pruning: %w", err)
		}
		return nil, ErrSessionInvalid
	}

	pair, err := createFirstPartySessionWithRefreshTx(
		ctx, tx, userID, clientType, deviceName, nextRefreshToken, now,
	)
	if errors.Is(err, errSuccessorUnavailable) {
		return nil, ErrSessionInvalid
	}
	if err != nil {
		return nil, fmt.Errorf("create recoverable session: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO auth_session_bootstrap_issuances
			(successor_hash, session_id, user_id, client_type, created_at)
		VALUES ($1, $2, $3, $4, $5)`,
		successorHash, pair.SessionID, userID, clientType, now); err != nil {
		if isUniqueViolation(err) {
			return nil, ErrSessionInvalid
		}
		return nil, fmt.Errorf("save session bootstrap issuance: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit session bootstrap: %w", err)
	}
	return pair, nil
}

// RefreshFirstPartySession consumes a refresh credential exactly once. A very
// recent duplicate receives a retryable conflict so concurrent client calls do
// not revoke their own session; an older replay revokes the entire device.
func (db *DB) RefreshFirstPartySession(ctx context.Context, credential string) (*AuthTokenPair, error) {
	return db.RefreshFirstPartySessionWithSuccessor(ctx, credential, "")
}

// RefreshFirstPartySessionWithSuccessor lets a client persist its next random
// credential before sending the request. A retry with the exact same old/new
// pair recovers an interrupted response without issuing another refresh token.
func (db *DB) RefreshFirstPartySessionWithSuccessor(ctx context.Context, credential, successor string) (*AuthTokenPair, error) {
	hash, ok := authTokenHash(credential, "mta_rt_")
	if !ok {
		return nil, ErrSessionInvalid
	}
	var successorHash string
	if successor != "" {
		var valid bool
		successorHash, valid = authTokenHash(successor, "mta_rt_")
		if !valid || successorHash == hash {
			return nil, ErrInvalidSuccessorToken
		}
	}
	now := time.Now().UTC()
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("begin session refresh: %w", err)
	}
	defer tx.Rollback()
	var row struct {
		SessionID         string         `db:"session_id"`
		UserID            string         `db:"user_id"`
		TokenExpiresAt    time.Time      `db:"token_expires_at"`
		ConsumedAt        sql.NullTime   `db:"consumed_at"`
		SuccessorHash     sql.NullString `db:"successor_hash"`
		InactiveExpiresAt time.Time      `db:"inactive_expires_at"`
		RevokedAt         sql.NullTime   `db:"revoked_at"`
	}
	err = tx.GetContext(ctx, &row, `
		SELECT t.session_id, s.user_id, t.expires_at AS token_expires_at,
		       t.consumed_at, t.successor_hash, s.inactive_expires_at, s.revoked_at
		FROM auth_refresh_tokens t JOIN auth_sessions s ON s.id = t.session_id
		WHERE t.token_hash = $1 FOR UPDATE OF t, s`, hash)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrSessionInvalid
	}
	if err != nil {
		return nil, fmt.Errorf("load session refresh credential: %w", err)
	}
	if row.RevokedAt.Valid || !now.Before(row.InactiveExpiresAt) || (!row.ConsumedAt.Valid && !now.Before(row.TokenExpiresAt)) {
		return nil, ErrSessionInvalid
	}
	if row.ConsumedAt.Valid {
		if successorHash != "" && row.SuccessorHash.Valid && row.SuccessorHash.String == successorHash {
			var expiresAt time.Time
			if err := tx.GetContext(ctx, &expiresAt, `
				SELECT expires_at FROM auth_refresh_tokens
				WHERE token_hash = $1 AND session_id = $2 AND consumed_at IS NULL`, successorHash, row.SessionID); err == nil && now.Before(expiresAt) {
				pair, accessHash, _, err := newAuthTokenPairWithRefresh(now, successor)
				if err != nil {
					return nil, err
				}
				pair.SessionID, pair.UserID, pair.InactiveExpiresAt = row.SessionID, row.UserID, row.InactiveExpiresAt
				if _, err := tx.ExecContext(ctx, `INSERT INTO auth_access_tokens (token_hash, session_id, expires_at) VALUES ($1, $2, $3)`, accessHash, row.SessionID, pair.AccessExpiresAt); err != nil {
					return nil, fmt.Errorf("save recovered access credential: %w", err)
				}
				if err := tx.Commit(); err != nil {
					return nil, fmt.Errorf("commit recovered refresh: %w", err)
				}
				return &pair, nil
			} else if err != nil && !errors.Is(err, sql.ErrNoRows) {
				return nil, fmt.Errorf("load successor credential: %w", err)
			}
			// The client knows both credentials, but has already advanced past
			// this pair. Reject the stale request without revoking the device.
			return nil, ErrSessionAlreadyRotated
		}
		if !now.Before(row.TokenExpiresAt) {
			return nil, ErrSessionInvalid
		}
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
	var pair AuthTokenPair
	var accessHash, refreshHash string
	if successor == "" {
		pair, accessHash, refreshHash, err = newAuthTokenPair(now)
	} else {
		pair, accessHash, refreshHash, err = newAuthTokenPairWithRefresh(now, successor)
	}
	if err != nil {
		return nil, err
	}
	pair.SessionID = row.SessionID
	pair.UserID = row.UserID
	if _, err := tx.ExecContext(ctx, `UPDATE auth_refresh_tokens SET consumed_at = $2, successor_hash = NULLIF($3, '') WHERE token_hash = $1`, hash, now, successorHash); err != nil {
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
