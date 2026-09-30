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
)

const recoveryCodeCount = 10

// ErrRecoveryCodeInvalid means a code is malformed, unknown, or already used.
var ErrRecoveryCodeInvalid = errors.New("recovery code is invalid or already used")

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

// ReplaceRecoveryCodes invalidates every prior code under the user's row lock.
// Plaintext codes leave the server only in this response and cannot be listed.
func (db *DB) ReplaceRecoveryCodes(ctx context.Context, userID string) ([]string, error) {
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("begin recovery code replacement: %w", err)
	}
	defer tx.Rollback()
	var lockedID string
	if err := tx.GetContext(ctx, &lockedID, `SELECT id FROM users WHERE id = $1 FOR UPDATE`, userID); err != nil {
		return nil, fmt.Errorf("lock recovery account: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM auth_recovery_codes WHERE user_id = $1`, userID); err != nil {
		return nil, fmt.Errorf("remove previous recovery codes: %w", err)
	}
	codes := make([]string, 0, recoveryCodeCount)
	for i := 0; i < recoveryCodeCount; i++ {
		code, hash, err := newRecoveryCode()
		if err != nil {
			return nil, err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO auth_recovery_codes (code_hash, user_id) VALUES ($1, $2)`, hash, userID); err != nil {
			return nil, fmt.Errorf("save recovery code: %w", err)
		}
		codes = append(codes, code)
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit recovery code replacement: %w", err)
	}
	return codes, nil
}

// RemainingRecoveryCodes returns the number of unused codes for an account.
func (db *DB) RemainingRecoveryCodes(ctx context.Context, userID string) (int, error) {
	var count int
	if err := db.GetContext(ctx, &count, `SELECT COUNT(*) FROM auth_recovery_codes WHERE user_id = $1 AND consumed_at IS NULL`, userID); err != nil {
		return 0, fmt.Errorf("count recovery codes: %w", err)
	}
	return count, nil
}

// RedeemRecoveryCode consumes the code and creates its device session in one
// transaction. A failed session write therefore cannot burn the only code.
func (db *DB) RedeemRecoveryCode(ctx context.Context, code, clientType, deviceName, nextRefreshToken string) (*AuthTokenPair, error) {
	hash, valid := parseRecoveryCode(code)
	if !valid {
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
	err = tx.GetContext(ctx, &userID, `SELECT user_id FROM auth_recovery_codes WHERE code_hash = $1`, hash)
	if errors.Is(err, sql.ErrNoRows) {
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
	err = tx.GetContext(ctx, &recovery, `
		SELECT user_id, consumed_at, consumed_session_id, successor_hash
		FROM auth_recovery_codes
		WHERE code_hash = $1 AND user_id = $2
		FOR UPDATE`, hash, lockedID)
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
			return nil, ErrRecoveryCodeInvalid
		}
		if err != nil {
			return nil, fmt.Errorf("recover recovery-code sign-in: %w", err)
		}
		if err := tx.Commit(); err != nil {
			return nil, fmt.Errorf("commit recovered recovery-code sign-in: %w", err)
		}
		return pair, nil
	}
	pair, err := createFirstPartySessionWithRefreshTx(ctx, tx, recovery.UserID, clientType, deviceName, nextRefreshToken, now)
	if errors.Is(err, errSuccessorUnavailable) {
		return nil, ErrRecoveryCodeInvalid
	}
	if err != nil {
		return nil, fmt.Errorf("create recovered session: %w", err)
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE auth_recovery_codes
		SET consumed_at = $2, consumed_session_id = $3, successor_hash = $4
		WHERE code_hash = $1 AND consumed_at IS NULL AND user_id = $5`,
		hash, now, pair.SessionID, successorHash, recovery.UserID)
	if err != nil {
		return nil, fmt.Errorf("consume recovery code: %w", err)
	}
	if affected, err := result.RowsAffected(); err != nil {
		return nil, fmt.Errorf("confirm recovery code consumption: %w", err)
	} else if affected != 1 {
		return nil, ErrRecoveryCodeInvalid
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit recovery sign-in: %w", err)
	}
	return pair, nil
}
