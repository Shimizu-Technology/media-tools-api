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

func (db *DB) RemainingRecoveryCodes(ctx context.Context, userID string) (int, error) {
	var count int
	if err := db.GetContext(ctx, &count, `SELECT COUNT(*) FROM auth_recovery_codes WHERE user_id = $1 AND consumed_at IS NULL`, userID); err != nil {
		return 0, fmt.Errorf("count recovery codes: %w", err)
	}
	return count, nil
}

// RedeemRecoveryCode consumes the code and creates its device session in one
// transaction. A failed session write therefore cannot burn the only code.
func (db *DB) RedeemRecoveryCode(ctx context.Context, code, clientType, deviceName string) (*AuthTokenPair, error) {
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
	now := time.Now().UTC()
	pair, accessHash, refreshHash, err := newAuthTokenPair(now)
	if err != nil {
		return nil, err
	}
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("begin recovery sign-in: %w", err)
	}
	defer tx.Rollback()
	var userID string
	// Match replacement's lock order (account, then code). A concurrent rotate
	// can invalidate this candidate while we wait, so consumption is rechecked.
	err = tx.GetContext(ctx, &userID, `SELECT user_id FROM auth_recovery_codes WHERE code_hash = $1 AND consumed_at IS NULL`, hash)
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
	err = tx.GetContext(ctx, &userID, `
		UPDATE auth_recovery_codes SET consumed_at = $2
		WHERE code_hash = $1 AND consumed_at IS NULL RETURNING user_id`, hash, now)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrRecoveryCodeInvalid
	}
	if err != nil {
		return nil, fmt.Errorf("consume recovery code: %w", err)
	}
	if err := tx.QueryRowContext(ctx, `
		INSERT INTO auth_sessions (user_id, client_type, device_name, last_used_at, inactive_expires_at)
		VALUES ($1, $2, $3, $4, $5) RETURNING id`,
		userID, clientType, deviceName, now, pair.InactiveExpiresAt).Scan(&pair.SessionID); err != nil {
		return nil, fmt.Errorf("create recovered session: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO auth_access_tokens (token_hash, session_id, expires_at) VALUES ($1, $2, $3)`, accessHash, pair.SessionID, pair.AccessExpiresAt); err != nil {
		return nil, fmt.Errorf("save recovered access credential: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO auth_refresh_tokens (token_hash, session_id, expires_at) VALUES ($1, $2, $3)`, refreshHash, pair.SessionID, pair.InactiveExpiresAt); err != nil {
		return nil, fmt.Errorf("save recovered refresh credential: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit recovery sign-in: %w", err)
	}
	pair.UserID = userID
	return &pair, nil
}
