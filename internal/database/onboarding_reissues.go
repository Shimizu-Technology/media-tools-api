package database

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
)

const OnboardingReissueTTL = 24 * time.Hour

var (
	ErrOnboardingReissueInvalid    = errors.New("onboarding rescue link is invalid or already used")
	ErrOnboardingReissueNotAllowed = errors.New("account already has a sign-in recovery method")
	ErrOnboardingAccountNotFound   = errors.New("onboarding account not found")
)

type AuthOnboardingReissue struct {
	ID        string    `json:"id" db:"id"`
	UserID    string    `json:"user_id" db:"user_id"`
	Email     string    `json:"email" db:"email"`
	Name      string    `json:"name" db:"name"`
	ExpiresAt time.Time `json:"expires_at" db:"expires_at"`
	CreatedAt time.Time `json:"created_at" db:"created_at"`
}

func onboardingReissueTokenHash(token string) (string, bool) {
	return authTokenHash(strings.TrimSpace(token), "mta_onb_")
}

// ValidOnboardingReissueToken validates the bearer-token shape before the web
// adapter moves a URL fragment into its protected cookie.
func ValidOnboardingReissueToken(token string) bool {
	_, ok := onboardingReissueTokenHash(token)
	return ok
}

func (db *DB) CreateOnboardingReissue(ctx context.Context, userID string) (*AuthOnboardingReissue, string, error) {
	userID = strings.TrimSpace(userID)
	if uuid.Validate(userID) != nil {
		return nil, "", ErrOnboardingAccountNotFound
	}
	token, err := randomAuthToken("mta_onb_")
	if err != nil {
		return nil, "", err
	}
	tokenHash, _ := onboardingReissueTokenHash(token)
	now := time.Now().UTC()
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return nil, "", fmt.Errorf("begin onboarding rescue creation: %w", err)
	}
	defer tx.Rollback()

	var account struct {
		ID    string `db:"id"`
		Email string `db:"email"`
		Name  string `db:"name"`
	}
	err = tx.GetContext(ctx, &account, `SELECT id, email, name FROM users WHERE id = $1 FOR UPDATE`, userID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, "", ErrOnboardingAccountNotFound
	}
	if err != nil {
		return nil, "", fmt.Errorf("lock onboarding account: %w", err)
	}
	if allowed, err := onboardingRescueAllowedTx(ctx, tx, account.ID); err != nil {
		return nil, "", err
	} else if !allowed {
		return nil, "", ErrOnboardingReissueNotAllowed
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE auth_onboarding_reissues SET revoked_at = $2
		WHERE user_id = $1 AND consumed_at IS NULL AND revoked_at IS NULL`, account.ID, now); err != nil {
		return nil, "", fmt.Errorf("supersede onboarding rescue: %w", err)
	}
	reissue := &AuthOnboardingReissue{UserID: account.ID, Email: account.Email, Name: account.Name}
	if err := tx.QueryRowContext(ctx, `
		INSERT INTO auth_onboarding_reissues (user_id, token_hash, expires_at)
		VALUES ($1, $2, $3)
		RETURNING id, expires_at, created_at`, account.ID, tokenHash, now.Add(OnboardingReissueTTL)).Scan(
		&reissue.ID, &reissue.ExpiresAt, &reissue.CreatedAt,
	); err != nil {
		return nil, "", fmt.Errorf("create onboarding rescue: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return nil, "", fmt.Errorf("commit onboarding rescue creation: %w", err)
	}
	return reissue, token, nil
}

func (db *DB) RedeemOnboardingReissue(ctx context.Context, token, clientType, deviceName, nextRefreshToken string) (*AuthTokenPair, error) {
	return db.redeemOnboardingReissue(ctx, token, clientType, deviceName, nextRefreshToken, nil, false, false)
}

// RedeemWebOnboardingReissue performs the rescue and any browser-account
// switch atomically. Existing sessions for the rescued account are also
// revoked by the shared redemption transaction below.
func (db *DB) RedeemWebOnboardingReissue(ctx context.Context, token, nextRefreshToken string, existingCredentials []string) (*AuthTokenPair, error) {
	return db.redeemOnboardingReissue(ctx, token, "web", "Browser", nextRefreshToken, existingCredentials, true, true)
}

func (db *DB) redeemOnboardingReissue(ctx context.Context, token, clientType, deviceName, nextRefreshToken string, existingCredentials []string, distinguishUnavailableSuccessor, requireOnboarding bool) (*AuthTokenPair, error) {
	hash, ok := onboardingReissueTokenHash(token)
	if !ok {
		return nil, ErrOnboardingReissueInvalid
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
		return nil, fmt.Errorf("begin onboarding rescue redemption: %w", err)
	}
	defer tx.Rollback()

	var candidateUserID string
	err = tx.GetContext(ctx, &candidateUserID, `SELECT user_id FROM auth_onboarding_reissues WHERE token_hash = $1`, hash)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrOnboardingReissueInvalid
	}
	if err != nil {
		return nil, fmt.Errorf("find onboarding rescue account: %w", err)
	}
	var lockedID string
	err = tx.GetContext(ctx, &lockedID, `SELECT id FROM users WHERE id = $1 FOR UPDATE`, candidateUserID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrOnboardingReissueInvalid
	}
	if err != nil {
		return nil, fmt.Errorf("lock onboarding rescue account: %w", err)
	}

	var reissue struct {
		ID         string         `db:"id"`
		UserID     string         `db:"user_id"`
		ExpiresAt  time.Time      `db:"expires_at"`
		ConsumedAt sql.NullTime   `db:"consumed_at"`
		SessionID  sql.NullString `db:"consumed_session_id"`
		Successor  sql.NullString `db:"successor_hash"`
		RevokedAt  sql.NullTime   `db:"revoked_at"`
	}
	err = tx.GetContext(ctx, &reissue, `
		SELECT id, user_id, expires_at, consumed_at, consumed_session_id,
		       successor_hash, revoked_at
		FROM auth_onboarding_reissues WHERE token_hash = $1 AND user_id = $2 FOR UPDATE`, hash, lockedID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrOnboardingReissueInvalid
	}
	if err != nil {
		return nil, fmt.Errorf("load onboarding rescue: %w", err)
	}
	if reissue.ConsumedAt.Valid {
		if !reissue.SessionID.Valid || !reissue.Successor.Valid || reissue.Successor.String != successorHash {
			return nil, ErrOnboardingReissueInvalid
		}
		pair, err := recoverCredentialIssuanceTx(ctx, tx, reissue.SessionID.String, reissue.UserID, nextRefreshToken, reissue.ConsumedAt.Time, now)
		if errors.Is(err, ErrSessionInvalid) {
			return nil, ErrOnboardingReissueInvalid
		}
		if err != nil {
			return nil, fmt.Errorf("recover onboarding rescue: %w", err)
		}
		if err := revokeBrowserSessionsByCredentialTx(ctx, tx, existingCredentials, pair.SessionID, now); err != nil {
			return nil, err
		}
		if err := tx.Commit(); err != nil {
			return nil, fmt.Errorf("commit recovered onboarding rescue: %w", err)
		}
		return pair, nil
	}
	if reissue.RevokedAt.Valid || !now.Before(reissue.ExpiresAt) {
		return nil, ErrOnboardingReissueInvalid
	}
	if allowed, err := onboardingRescueAllowedTx(ctx, tx, lockedID); err != nil {
		return nil, err
	} else if !allowed {
		return nil, ErrOnboardingReissueNotAllowed
	}
	// Native clients cannot call the cookie-only web completion endpoint. The
	// latest redemption therefore decides whether the web-only gate applies.
	if _, err := tx.ExecContext(ctx, `UPDATE users SET onboarding_required = $2 WHERE id = $1`, lockedID, requireOnboarding); err != nil {
		return nil, fmt.Errorf("set rescued account onboarding requirement: %w", err)
	}
	pair, err := createFirstPartySessionWithRefreshTx(ctx, tx, lockedID, clientType, deviceName, nextRefreshToken, now)
	if errors.Is(err, errSuccessorUnavailable) {
		if distinguishUnavailableSuccessor {
			return nil, ErrInvalidSuccessorToken
		}
		return nil, ErrOnboardingReissueInvalid
	}
	if err != nil {
		return nil, fmt.Errorf("create onboarding rescue session: %w", err)
	}
	result, err := tx.ExecContext(ctx, `
		UPDATE auth_onboarding_reissues
		SET consumed_at = $2, consumed_session_id = $3, successor_hash = $4
		WHERE id = $1 AND consumed_at IS NULL AND revoked_at IS NULL`, reissue.ID, now, pair.SessionID, successorHash)
	if err != nil {
		return nil, fmt.Errorf("consume onboarding rescue: %w", err)
	}
	if affected, err := result.RowsAffected(); err != nil {
		return nil, fmt.Errorf("confirm onboarding rescue consumption: %w", err)
	} else if affected != 1 {
		return nil, ErrOnboardingReissueInvalid
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE auth_sessions SET revoked_at = COALESCE(revoked_at, $3)
		WHERE user_id = $1 AND id <> $2`, lockedID, pair.SessionID, now); err != nil {
		return nil, fmt.Errorf("revoke stranded onboarding sessions: %w", err)
	}
	if err := revokeBrowserSessionsByCredentialTx(ctx, tx, existingCredentials, pair.SessionID, now); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit onboarding rescue redemption: %w", err)
	}
	return pair, nil
}

// OnboardingSecurityStatus reports the durable factors required before a web
// onboarding session can leave the guided setup route.
func (db *DB) OnboardingSecurityStatus(ctx context.Context, userID string) (passkeys, recoveryCodes int, err error) {
	err = db.QueryRowContext(ctx, `
		SELECT
			(SELECT COUNT(*) FROM auth_passkey_credentials WHERE user_id = $1),
			(SELECT COUNT(*) FROM auth_recovery_codes WHERE user_id = $1 AND active AND consumed_at IS NULL)`,
		userID).Scan(&passkeys, &recoveryCodes)
	if err != nil {
		return 0, 0, fmt.Errorf("load onboarding security status: %w", err)
	}
	return passkeys, recoveryCodes, nil
}

// CompleteOnboarding serializes with recovery rotation and rescue redemption
// on the user row, then clears the durable requirement only when both factors
// are committed and usable. Repeating a successful completion is safe.
func (db *DB) CompleteOnboarding(ctx context.Context, userID string) (bool, error) {
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return false, fmt.Errorf("begin onboarding completion: %w", err)
	}
	defer tx.Rollback()
	var lockedID string
	if err := tx.GetContext(ctx, &lockedID, `SELECT id FROM users WHERE id = $1 FOR UPDATE`, userID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return false, nil
		}
		return false, fmt.Errorf("lock onboarding account: %w", err)
	}
	var status struct {
		Passkeys      int `db:"passkeys"`
		RecoveryCodes int `db:"recovery_codes"`
	}
	if err := tx.GetContext(ctx, &status, `
		SELECT
			(SELECT COUNT(*) FROM auth_passkey_credentials WHERE user_id = $1) AS passkeys,
			(SELECT COUNT(*) FROM auth_recovery_codes
			 WHERE user_id = $1 AND active AND consumed_at IS NULL) AS recovery_codes`, lockedID); err != nil {
		return false, fmt.Errorf("verify onboarding security factors: %w", err)
	}
	if status.Passkeys == 0 || status.RecoveryCodes == 0 {
		return false, nil
	}
	if _, err := tx.ExecContext(ctx, `UPDATE users SET onboarding_required = FALSE WHERE id = $1`, lockedID); err != nil {
		return false, fmt.Errorf("complete onboarding: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return false, fmt.Errorf("commit onboarding completion: %w", err)
	}
	return true, nil
}

func onboardingRescueAllowedTx(ctx context.Context, tx interface {
	GetContext(context.Context, any, string, ...any) error
}, userID string) (bool, error) {
	var blocked bool
	if err := tx.GetContext(ctx, &blocked, `
		SELECT EXISTS (SELECT 1 FROM auth_passkey_credentials WHERE user_id = $1)
		    OR EXISTS (
		        SELECT 1 FROM auth_recovery_codes
		        WHERE user_id = $1 AND active AND consumed_at IS NULL
		    )`, userID); err != nil {
		return false, fmt.Errorf("check onboarding recovery methods: %w", err)
	}
	return !blocked, nil
}
