package database

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/go-webauthn/webauthn/webauthn"
)

var (
	ErrPasskeyCeremonyInvalid   = errors.New("passkey ceremony is invalid or expired")
	ErrPasskeyCredentialExists  = errors.New("passkey credential already exists")
	ErrPasskeyCredentialChanged = errors.New("passkey credential changed during sign-in")
)

// StoredPasskey includes a revision so concurrent assertions cannot overwrite
// newer authenticator state (especially signature counters and backup flags).
type StoredPasskey struct {
	Credential webauthn.Credential
	Revision   int64
}

func (db *DB) ListPasskeysForUser(ctx context.Context, userID string) ([]StoredPasskey, error) {
	var rows []struct {
		Credential []byte `db:"credential"`
		Revision   int64  `db:"revision"`
	}
	if err := db.SelectContext(ctx, &rows, `
		SELECT credential, revision FROM auth_passkey_credentials
		WHERE user_id = $1 ORDER BY created_at`, userID); err != nil {
		return nil, fmt.Errorf("list passkeys: %w", err)
	}
	credentials := make([]StoredPasskey, 0, len(rows))
	for _, row := range rows {
		var credential webauthn.Credential
		if err := json.Unmarshal(row.Credential, &credential); err != nil {
			return nil, fmt.Errorf("decode passkey credential: %w", err)
		}
		credentials = append(credentials, StoredPasskey{Credential: credential, Revision: row.Revision})
	}
	return credentials, nil
}

// CountPasskeysForUser lets clients resume security setup after a registration
// response is lost without exposing credential IDs or authenticator metadata.
func (db *DB) CountPasskeysForUser(ctx context.Context, userID string) (int, error) {
	var count int
	if err := db.GetContext(ctx, &count, `SELECT COUNT(*) FROM auth_passkey_credentials WHERE user_id = $1`, userID); err != nil {
		return 0, fmt.Errorf("count passkeys: %w", err)
	}
	return count, nil
}

func (db *DB) GetPasskeyCredentialOwner(ctx context.Context, credentialID []byte) (string, error) {
	var userID string
	if err := db.GetContext(ctx, &userID, `
		SELECT user_id FROM auth_passkey_credentials WHERE credential_id = $1`, credentialID); err != nil {
		return "", fmt.Errorf("find passkey owner: %w", err)
	}
	return userID, nil
}

func (db *DB) AddPasskeyCredential(ctx context.Context, userID string, credential *webauthn.Credential) error {
	if credential == nil || len(credential.ID) == 0 {
		return fmt.Errorf("passkey credential ID is required")
	}
	encoded, err := json.Marshal(credential)
	if err != nil {
		return fmt.Errorf("encode passkey credential: %w", err)
	}
	result, err := db.ExecContext(ctx, `
		INSERT INTO auth_passkey_credentials (credential_id, user_id, credential)
		VALUES ($1, $2, $3) ON CONFLICT (credential_id) DO NOTHING`, credential.ID, userID, string(encoded))
	if err != nil {
		return fmt.Errorf("save passkey credential: %w", err)
	}
	if count, err := result.RowsAffected(); err != nil {
		return fmt.Errorf("confirm passkey save: %w", err)
	} else if count != 1 {
		return ErrPasskeyCredentialExists
	}
	return nil
}

// UpdatePasskeyCredential writes all assertion-mutated credential fields only
// if the version loaded for signature validation is still current.
func (db *DB) UpdatePasskeyCredential(ctx context.Context, userID string, credential *webauthn.Credential, revision int64) error {
	if credential == nil || len(credential.ID) == 0 {
		return fmt.Errorf("passkey credential ID is required")
	}
	encoded, err := json.Marshal(credential)
	if err != nil {
		return fmt.Errorf("encode updated passkey credential: %w", err)
	}
	result, err := db.ExecContext(ctx, `
		UPDATE auth_passkey_credentials
		SET credential = $3, revision = revision + 1, last_used_at = NOW()
		WHERE credential_id = $1 AND user_id = $2 AND revision = $4`, credential.ID, userID, string(encoded), revision)
	if err != nil {
		return fmt.Errorf("update passkey credential: %w", err)
	}
	if count, err := result.RowsAffected(); err != nil {
		return fmt.Errorf("confirm passkey update: %w", err)
	} else if count != 1 {
		return ErrPasskeyCredentialChanged
	}
	return nil
}

// CompletePasskeyLogin persists the assertion's updated authenticator state,
// creates the device session with the client's already-saved refresh token,
// and links the consumed ceremony in one transaction. A response can then be
// recovered without verifying the assertion or creating another session.
func (db *DB) CompletePasskeyLogin(ctx context.Context, ceremonyID, userID string, credential *webauthn.Credential, revision int64, clientType, deviceName, nextRefreshToken string) (*AuthTokenPair, error) {
	if credential == nil || len(credential.ID) == 0 {
		return nil, fmt.Errorf("passkey credential ID is required")
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
	encoded, err := json.Marshal(credential)
	if err != nil {
		return nil, fmt.Errorf("encode updated passkey credential: %w", err)
	}
	now := time.Now().UTC()
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("begin passkey session issuance: %w", err)
	}
	defer tx.Rollback()
	var lockedID string
	err = tx.GetContext(ctx, &lockedID, `
		SELECT id FROM auth_passkey_ceremonies
		WHERE id = $1 AND kind = 'login' AND consumed_at IS NOT NULL AND completed_at IS NULL
		FOR UPDATE`, ceremonyID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrPasskeyCeremonyInvalid
	}
	if err != nil {
		return nil, fmt.Errorf("lock consumed passkey ceremony: %w", err)
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE auth_passkey_credentials
		SET credential = $3, revision = revision + 1, last_used_at = $5
		WHERE credential_id = $1 AND user_id = $2 AND revision = $4`, credential.ID, userID, string(encoded), revision, now)
	if err != nil {
		return nil, fmt.Errorf("update passkey credential: %w", err)
	}
	if count, err := result.RowsAffected(); err != nil {
		return nil, fmt.Errorf("confirm passkey update: %w", err)
	} else if count != 1 {
		return nil, ErrPasskeyCredentialChanged
	}
	pair, err := createFirstPartySessionWithRefreshTx(ctx, tx, userID, clientType, deviceName, nextRefreshToken, now)
	if errors.Is(err, errSuccessorUnavailable) {
		return nil, ErrPasskeyCeremonyInvalid
	}
	if err != nil {
		return nil, fmt.Errorf("create passkey session: %w", err)
	}
	result, err = tx.ExecContext(ctx, `
		UPDATE auth_passkey_ceremonies
		SET verified_user_id = $2, issued_session_id = $3,
		    successor_hash = $4, completed_at = $5
		WHERE id = $1 AND completed_at IS NULL`, ceremonyID, userID, pair.SessionID, successorHash, now)
	if err != nil {
		return nil, fmt.Errorf("link passkey session: %w", err)
	}
	if count, err := result.RowsAffected(); err != nil {
		return nil, fmt.Errorf("confirm passkey session link: %w", err)
	} else if count != 1 {
		return nil, ErrPasskeyCeremonyInvalid
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit passkey session issuance: %w", err)
	}
	return pair, nil
}

// RecoverPasskeyLogin returns the session from a successful, recent ceremony
// only when the caller presents the exact client-generated refresh token.
func (db *DB) RecoverPasskeyLogin(ctx context.Context, ceremonyID, nextRefreshToken string) (*AuthTokenPair, error) {
	successorHash, err := refreshSuccessorHash(nextRefreshToken)
	if err != nil {
		return nil, err
	}
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("begin passkey session recovery: %w", err)
	}
	defer tx.Rollback()
	var row struct {
		UserID        sql.NullString `db:"verified_user_id"`
		SessionID     sql.NullString `db:"issued_session_id"`
		SuccessorHash sql.NullString `db:"successor_hash"`
		CompletedAt   sql.NullTime   `db:"completed_at"`
	}
	err = tx.GetContext(ctx, &row, `
		SELECT verified_user_id, issued_session_id, successor_hash, completed_at
		FROM auth_passkey_ceremonies
		WHERE id = $1 AND kind = 'login'
		FOR UPDATE`, ceremonyID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrPasskeyCeremonyInvalid
	}
	if err != nil {
		return nil, fmt.Errorf("load completed passkey ceremony: %w", err)
	}
	if !row.UserID.Valid || !row.SessionID.Valid || !row.SuccessorHash.Valid ||
		!row.CompletedAt.Valid || row.SuccessorHash.String != successorHash {
		return nil, ErrPasskeyCeremonyInvalid
	}
	pair, err := recoverCredentialIssuanceTx(
		ctx, tx, row.SessionID.String, row.UserID.String,
		nextRefreshToken, row.CompletedAt.Time, time.Now().UTC(),
	)
	if errors.Is(err, ErrSessionInvalid) {
		return nil, ErrPasskeyCeremonyInvalid
	}
	if err != nil {
		return nil, fmt.Errorf("recover passkey session: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit recovered passkey session: %w", err)
	}
	return pair, nil
}

// CreatePasskeyCeremony stores the library's session data atomically. The
// client receives only a random ceremony ID, never trusted challenge state.
func (db *DB) CreatePasskeyCeremony(ctx context.Context, kind, userID, authBinding string, session *webauthn.SessionData) (string, error) {
	if session == nil || session.Challenge == "" ||
		!((kind == "register" && userID != "" && authBinding != "") || (kind == "login" && userID == "" && authBinding == "")) {
		return "", fmt.Errorf("invalid passkey ceremony scope")
	}
	now := time.Now().UTC()
	expiresAt := session.Expires
	if expiresAt.IsZero() || expiresAt.After(now.Add(5*time.Minute)) {
		expiresAt = now.Add(5 * time.Minute)
	}
	if !expiresAt.After(now) {
		return "", ErrPasskeyCeremonyInvalid
	}
	encoded, err := json.Marshal(session)
	if err != nil {
		return "", fmt.Errorf("encode passkey ceremony: %w", err)
	}
	// Keep replay evidence briefly, then bound storage without a separate job.
	// The expiry index makes this cleanup cheap when no old rows exist. Bound
	// each deletion so a backlog does not make sign-in wait on a large purge.
	if _, err := db.ExecContext(ctx, `
		DELETE FROM auth_passkey_ceremonies WHERE id IN (
			SELECT id FROM auth_passkey_ceremonies
			WHERE expires_at < NOW() - INTERVAL '1 day'
			ORDER BY expires_at LIMIT 1000
		)`); err != nil {
		return "", fmt.Errorf("prune expired passkey ceremonies: %w", err)
	}
	var id string
	var accountID any
	if userID != "" {
		accountID = userID
	}
	if err := db.QueryRowContext(ctx, `
		INSERT INTO auth_passkey_ceremonies (kind, user_id, auth_binding, session_data, expires_at)
		VALUES ($1, $2, $3, $4, $5) RETURNING id`, kind, accountID, authBinding, string(encoded), expiresAt).Scan(&id); err != nil {
		return "", fmt.Errorf("save passkey ceremony: %w", err)
	}
	return id, nil
}

// ConsumePasskeyCeremony is one-use even when WebAuthn verification fails.
// That prevents replay and keeps an attacker from probing one challenge.
func (db *DB) ConsumePasskeyCeremony(ctx context.Context, id, kind, userID, authBinding string) (*webauthn.SessionData, error) {
	var encoded []byte
	err := db.GetContext(ctx, &encoded, `
		UPDATE auth_passkey_ceremonies SET consumed_at = NOW()
		WHERE id = $1 AND kind = $2
		  AND COALESCE(user_id::text, '') = $3 AND auth_binding = $4
		  AND consumed_at IS NULL AND expires_at > NOW()
		RETURNING session_data`, id, kind, userID, authBinding)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrPasskeyCeremonyInvalid
	}
	if err != nil {
		return nil, fmt.Errorf("consume passkey ceremony: %w", err)
	}
	var session webauthn.SessionData
	if err := json.Unmarshal(encoded, &session); err != nil {
		return nil, fmt.Errorf("decode passkey ceremony: %w", err)
	}
	return &session, nil
}
