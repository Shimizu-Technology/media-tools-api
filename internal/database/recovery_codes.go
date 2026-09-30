package database

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base32"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jmoiron/sqlx"
)

const (
	recoveryCodeCount       = 10
	recoveryRotationPending = 24 * time.Hour
)

var (
	// ErrRecoveryCodeInvalid means a code is malformed, unknown, or already used.
	ErrRecoveryCodeInvalid = errors.New("recovery code is invalid or already used")
	// ErrRecoveryRotationInvalid intentionally covers malformed, foreign,
	// replaced, and expired rotations without revealing another account's state.
	ErrRecoveryRotationInvalid = errors.New("recovery code rotation is invalid or expired")
)

type RecoveryCodeRotation struct {
	ID        string
	Codes     []string
	ExpiresAt time.Time
}

// Recovery codes contain 160 random bits. Their hashes can be stored with
// SHA-256 because guessing a code is infeasible even if the hashes leak.
func newRecoveryCode() (string, string, error) {
	random := make([]byte, 20)
	if _, err := rand.Read(random); err != nil {
		return "", "", fmt.Errorf("generate recovery code: %w", err)
	}
	encoded := base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(random)
	parts := make([]string, 0, 8)
	for i := 0; i < len(encoded); i += 4 {
		parts = append(parts, encoded[i:i+4])
	}
	return "MTR-" + strings.Join(parts, "-"), recoveryCodeHash(encoded), nil
}

func recoveryCodeHash(encoded string) string {
	sum := sha256.Sum256([]byte(encoded))
	return hex.EncodeToString(sum[:])
}

func parseRecoveryCode(code string) (string, bool) {
	compact := strings.ToUpper(strings.ReplaceAll(strings.TrimSpace(code), "-", ""))
	if !strings.HasPrefix(compact, "MTR") {
		return "", false
	}
	encoded := strings.TrimPrefix(compact, "MTR")
	if len(encoded) != 32 {
		return "", false
	}
	decoded, err := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(encoded)
	if err != nil || len(decoded) != 20 {
		return "", false
	}
	return recoveryCodeHash(encoded), true
}

// BeginRecoveryCodeRotation creates an inactive replacement set while leaving
// every active code untouched. Starting again discards any unconfirmed hashes;
// plaintext codes exist only in the successful response.
func (db *DB) BeginRecoveryCodeRotation(ctx context.Context, userID string) (*RecoveryCodeRotation, error) {
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("begin recovery code rotation: %w", err)
	}
	defer tx.Rollback()
	var lockedID string
	if err := tx.GetContext(ctx, &lockedID, `SELECT id FROM users WHERE id = $1 FOR UPDATE`, userID); err != nil {
		return nil, fmt.Errorf("lock recovery rotation account: %w", err)
	}
	// The account lock serializes this replacement with confirmation and code
	// redemption. Cascading deletion removes only inactive pending hashes.
	if _, err := tx.ExecContext(ctx, `
		DELETE FROM auth_recovery_code_rotations
		WHERE user_id = $1 AND confirmed_at IS NULL`, userID); err != nil {
		return nil, fmt.Errorf("discard unconfirmed recovery rotation: %w", err)
	}
	now := time.Now().UTC()
	rotation := &RecoveryCodeRotation{Codes: make([]string, 0, recoveryCodeCount), ExpiresAt: now.Add(recoveryRotationPending)}
	if err := tx.QueryRowContext(ctx, `
		INSERT INTO auth_recovery_code_rotations (user_id, expires_at)
		VALUES ($1, $2) RETURNING id`, userID, rotation.ExpiresAt).Scan(&rotation.ID); err != nil {
		return nil, fmt.Errorf("create recovery rotation: %w", err)
	}
	for i := 0; i < recoveryCodeCount; i++ {
		code, hash, err := newRecoveryCode()
		if err != nil {
			return nil, err
		}
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO auth_recovery_codes (code_hash, user_id, rotation_id, active)
			VALUES ($1, $2, $3, FALSE)`, hash, userID, rotation.ID); err != nil {
			return nil, fmt.Errorf("save pending recovery code: %w", err)
		}
		rotation.Codes = append(rotation.Codes, code)
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit recovery code rotation: %w", err)
	}
	return rotation, nil
}

// ConfirmRecoveryCodeRotation atomically swaps the active set. Repeating a
// successful confirmation is idempotent and never changes a newer active set.
func (db *DB) ConfirmRecoveryCodeRotation(ctx context.Context, userID, rotationID string) (int, error) {
	if uuid.Validate(rotationID) != nil {
		return 0, ErrRecoveryRotationInvalid
	}
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return 0, fmt.Errorf("begin recovery rotation confirmation: %w", err)
	}
	defer tx.Rollback()
	var lockedID string
	err = tx.GetContext(ctx, &lockedID, `SELECT id FROM users WHERE id = $1 FOR UPDATE`, userID)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrRecoveryRotationInvalid
	}
	if err != nil {
		return 0, fmt.Errorf("lock recovery confirmation account: %w", err)
	}
	var rotation struct {
		ExpiresAt   time.Time    `db:"expires_at"`
		ConfirmedAt sql.NullTime `db:"confirmed_at"`
	}
	err = tx.GetContext(ctx, &rotation, `
		SELECT expires_at, confirmed_at
		FROM auth_recovery_code_rotations
		WHERE id = $1 AND user_id = $2
		FOR UPDATE`, rotationID, lockedID)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrRecoveryRotationInvalid
	}
	if err != nil {
		return 0, fmt.Errorf("load recovery rotation: %w", err)
	}
	if rotation.ConfirmedAt.Valid {
		var counts struct {
			Total     int `db:"total"`
			Remaining int `db:"remaining"`
		}
		if err := tx.GetContext(ctx, &counts, `
			SELECT COUNT(*) AS total,
			       COUNT(*) FILTER (WHERE consumed_at IS NULL) AS remaining
			FROM auth_recovery_codes
			WHERE user_id = $1 AND rotation_id = $2 AND active`, userID, rotationID); err != nil {
			return 0, fmt.Errorf("count confirmed recovery codes: %w", err)
		}
		if counts.Total != recoveryCodeCount {
			return 0, ErrRecoveryRotationInvalid
		}
		return counts.Remaining, nil
	}
	now := time.Now().UTC()
	if !now.Before(rotation.ExpiresAt) {
		if _, err := tx.ExecContext(ctx, `DELETE FROM auth_recovery_code_rotations WHERE id = $1`, rotationID); err != nil {
			return 0, fmt.Errorf("remove expired recovery rotation: %w", err)
		}
		if err := tx.Commit(); err != nil {
			return 0, fmt.Errorf("commit expired recovery rotation cleanup: %w", err)
		}
		return 0, ErrRecoveryRotationInvalid
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM auth_recovery_codes WHERE user_id = $1 AND active`, userID); err != nil {
		return 0, fmt.Errorf("invalidate previous recovery codes: %w", err)
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE auth_recovery_codes SET active = TRUE
		WHERE user_id = $1 AND rotation_id = $2 AND NOT active AND consumed_at IS NULL`, userID, rotationID)
	if err != nil {
		return 0, fmt.Errorf("activate pending recovery codes: %w", err)
	}
	activated, err := result.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("count activated recovery codes: %w", err)
	}
	if activated != recoveryCodeCount {
		return 0, fmt.Errorf("pending recovery set has %d codes, want %d", activated, recoveryCodeCount)
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE auth_recovery_code_rotations SET confirmed_at = $2
		WHERE id = $1 AND confirmed_at IS NULL`, rotationID, now); err != nil {
		return 0, fmt.Errorf("mark recovery rotation confirmed: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
		DELETE FROM auth_recovery_code_rotations r
		WHERE r.user_id = $1 AND r.id <> $2 AND r.confirmed_at IS NOT NULL
		  AND NOT EXISTS (SELECT 1 FROM auth_recovery_codes c WHERE c.rotation_id = r.id)`, userID, rotationID); err != nil {
		return 0, fmt.Errorf("prune superseded recovery rotations: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("commit recovery rotation confirmation: %w", err)
	}
	return int(activated), nil
}

// RemainingRecoveryCodes returns the number of unused codes for an account.
func (db *DB) RemainingRecoveryCodes(ctx context.Context, userID string) (int, error) {
	var count int
	if err := db.GetContext(ctx, &count, `SELECT COUNT(*) FROM auth_recovery_codes WHERE user_id = $1 AND active AND consumed_at IS NULL`, userID); err != nil {
		return 0, fmt.Errorf("count recovery codes: %w", err)
	}
	return count, nil
}

// RedeemRecoveryCode consumes the code and creates its device session in one
// transaction. A failed session write therefore cannot burn the only code.
func (db *DB) RedeemRecoveryCode(ctx context.Context, code, clientType, deviceName, nextRefreshToken string) (*AuthTokenPair, error) {
	return db.redeemRecoveryCode(ctx, code, clientType, deviceName, nextRefreshToken, nil, false)
}

// RedeemWebRecoveryCode atomically consumes or recovers a recovery code,
// creates the cookie-backed browser session, and revokes sessions whose
// refresh credentials were already stored in this browser. If any step fails,
// the existing browser session and the recovery code remain unchanged.
//
// An empty code is accepted only for exact response-loss recovery: the saved
// HttpOnly successor identifies a previously committed redemption without
// exposing either credential to JavaScript.
func (db *DB) RedeemWebRecoveryCode(ctx context.Context, code, nextRefreshToken string, existingRefreshTokens []string) (*AuthTokenPair, error) {
	return db.redeemRecoveryCode(ctx, code, "web", "Browser", nextRefreshToken, existingRefreshTokens, true)
}

func (db *DB) redeemRecoveryCode(ctx context.Context, code, clientType, deviceName, nextRefreshToken string, existingRefreshTokens []string, allowSuccessorRecovery bool) (*AuthTokenPair, error) {
	hash, valid := parseRecoveryCode(code)
	if !valid && !(allowSuccessorRecovery && strings.TrimSpace(code) == "") {
		return nil, ErrRecoveryCodeInvalid
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
		return nil, fmt.Errorf("begin recovery sign-in: %w", err)
	}
	defer tx.Rollback()
	var userID string
	// Match replacement's lock order (account, then code). A concurrent rotate
	// can invalidate this candidate while we wait, so consumption is rechecked.
	if valid {
		err = tx.GetContext(ctx, &userID, `SELECT user_id FROM auth_recovery_codes WHERE code_hash = $1 AND active`, hash)
	} else {
		err = tx.GetContext(ctx, &userID, `
			SELECT user_id FROM auth_recovery_codes
			WHERE successor_hash = $1 AND active AND consumed_at IS NOT NULL`, successorHash)
	}
	if errors.Is(err, sql.ErrNoRows) {
		if allowSuccessorRecovery && !valid {
			var occupied bool
			if lookupErr := tx.GetContext(ctx, &occupied, `SELECT EXISTS (SELECT 1 FROM auth_refresh_tokens WHERE token_hash = $1)`, successorHash); lookupErr != nil {
				return nil, fmt.Errorf("check recovery successor availability: %w", lookupErr)
			}
			if occupied {
				return nil, ErrInvalidSuccessorToken
			}
		}
		return nil, ErrRecoveryCodeInvalid
	}
	if err != nil {
		return nil, fmt.Errorf("find recovery account: %w", err)
	}
	var lockedID string
	err = tx.GetContext(ctx, &lockedID, `SELECT id FROM users WHERE id = $1 FOR UPDATE`, userID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrRecoveryCodeInvalid
	}
	if err != nil {
		return nil, fmt.Errorf("lock recovery account: %w", err)
	}
	var recovery struct {
		UserID     string         `db:"user_id"`
		ConsumedAt sql.NullTime   `db:"consumed_at"`
		SessionID  sql.NullString `db:"consumed_session_id"`
		Successor  sql.NullString `db:"successor_hash"`
	}
	if valid {
		err = tx.GetContext(ctx, &recovery, `
			SELECT user_id, consumed_at, consumed_session_id, successor_hash
			FROM auth_recovery_codes
			WHERE code_hash = $1 AND user_id = $2 AND active
			FOR UPDATE`, hash, lockedID)
	} else {
		err = tx.GetContext(ctx, &recovery, `
			SELECT user_id, consumed_at, consumed_session_id, successor_hash
			FROM auth_recovery_codes
			WHERE successor_hash = $1 AND user_id = $2 AND active AND consumed_at IS NOT NULL
			FOR UPDATE`, successorHash, lockedID)
	}
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrRecoveryCodeInvalid
	}
	if err != nil {
		return nil, fmt.Errorf("load recovery code: %w", err)
	}
	if recovery.ConsumedAt.Valid {
		if !recovery.SessionID.Valid || !recovery.Successor.Valid || recovery.Successor.String != successorHash {
			return nil, ErrRecoveryCodeInvalid
		}
		pair, err := recoverCredentialIssuanceTx(
			ctx, tx, recovery.SessionID.String, recovery.UserID,
			nextRefreshToken, recovery.ConsumedAt.Time, now,
		)
		if errors.Is(err, ErrSessionInvalid) {
			if allowSuccessorRecovery && !valid {
				return nil, ErrInvalidSuccessorToken
			}
			return nil, ErrRecoveryCodeInvalid
		}
		if err != nil {
			return nil, fmt.Errorf("recover recovery-code sign-in: %w", err)
		}
		if err := revokeBrowserSessionsByRefreshTx(ctx, tx, existingRefreshTokens, pair.SessionID, now); err != nil {
			return nil, err
		}
		if err := tx.Commit(); err != nil {
			return nil, fmt.Errorf("commit recovered recovery-code sign-in: %w", err)
		}
		return pair, nil
	}
	pair, err := createFirstPartySessionWithRefreshTx(ctx, tx, recovery.UserID, clientType, deviceName, nextRefreshToken, now)
	if errors.Is(err, errSuccessorUnavailable) {
		if allowSuccessorRecovery {
			return nil, ErrInvalidSuccessorToken
		}
		return nil, ErrRecoveryCodeInvalid
	}
	if err != nil {
		return nil, fmt.Errorf("create recovered session: %w", err)
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE auth_recovery_codes
		SET consumed_at = $2, consumed_session_id = $3, successor_hash = $4
		WHERE code_hash = $1 AND consumed_at IS NULL AND user_id = $5 AND active`,
		hash, now, pair.SessionID, successorHash, recovery.UserID)
	if err != nil {
		return nil, fmt.Errorf("consume recovery code: %w", err)
	}
	if affected, err := result.RowsAffected(); err != nil {
		return nil, fmt.Errorf("confirm recovery code consumption: %w", err)
	} else if affected != 1 {
		return nil, ErrRecoveryCodeInvalid
	}
	if err := revokeBrowserSessionsByRefreshTx(ctx, tx, existingRefreshTokens, pair.SessionID, now); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit recovery sign-in: %w", err)
	}
	return pair, nil
}

func revokeBrowserSessionsByRefreshTx(ctx context.Context, tx *sqlx.Tx, credentials []string, keepSessionID string, now time.Time) error {
	seen := make(map[string]struct{}, len(credentials))
	for _, credential := range credentials {
		hash, ok := authTokenHash(credential, "mta_rt_")
		if !ok {
			continue
		}
		if _, duplicate := seen[hash]; duplicate {
			continue
		}
		seen[hash] = struct{}{}
		if _, err := tx.ExecContext(ctx, `
			UPDATE auth_sessions s SET revoked_at = COALESCE(s.revoked_at, $3)
			FROM auth_refresh_tokens t
			WHERE t.session_id = s.id AND t.token_hash = $1 AND s.id <> $2`,
			hash, keepSessionID, now); err != nil {
			return fmt.Errorf("revoke replaced browser session: %w", err)
		}
	}
	return nil
}
