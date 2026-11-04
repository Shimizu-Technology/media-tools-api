package database

import (
	"context"
	"crypto/subtle"
	"database/sql"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jmoiron/sqlx"
)

var ErrEmailCodeInvalid = errors.New("email code invalid or expired")

type EmailChallenge struct {
	ID                 string     `db:"id"`
	Purpose            string     `db:"purpose"`
	Email              string     `db:"email"`
	UserID             *string    `db:"user_id"`
	CodeHash           string     `db:"code_hash"`
	PasswordHash       string     `db:"password_hash"`
	CredentialSnapshot string     `db:"credential_snapshot"`
	Name               string     `db:"name"`
	Attempts           int        `db:"attempts"`
	CreatedAt          time.Time  `db:"created_at"`
	ExpiresAt          time.Time  `db:"expires_at"`
	ConsumedAt         *time.Time `db:"consumed_at"`
}

func queueAuthEmailTx(ctx context.Context, tx *sqlx.Tx, id string, challengeID, userID *string, sealed string, expires time.Time) error {
	if _, err := tx.ExecContext(ctx, `INSERT INTO auth_email_outbox(id,challenge_id,user_id,sealed,expires_at) VALUES($1,$2,$3,$4,$5)`, id, challengeID, userID, sealed, expires); err != nil {
		return err
	}
	_, err := tx.ExecContext(ctx, `INSERT INTO background_jobs(job_type,resource_id,payload,max_attempts) VALUES('auth_email',$1,'{}',8)`, id)
	return err
}

// IssueEmailChallenge serializes every initiation for an address. The generic
// handler response is identical whether this stores a challenge, suppresses a
// resend within 60 seconds, or finds an ineligible/unknown account.
func (db *DB) IssueEmailChallenge(ctx context.Context, ch EmailChallenge, sealed string) (bool, error) {
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, ch.Email); err != nil {
		return false, err
	}
	// This history survives challenge replacement. Reserve sends before queueing,
	// so concurrent initiations and provider retries cannot reset the daily cap.
	var sends int
	var last sql.NullTime
	if err = tx.QueryRowContext(ctx, `SELECT COUNT(*),MAX(created_at) FROM auth_email_limits WHERE purpose=$1 AND email=$2 AND kind='send' AND created_at>NOW()-INTERVAL '24 hours'`, ch.Purpose, ch.Email).Scan(&sends, &last); err != nil {
		return false, err
	}
	if sends >= 5 || (last.Valid && time.Since(last.Time) < time.Minute*time.Duration(1<<max(0, sends-1))) {
		return false, nil
	}
	var user struct {
		ID    string `db:"id"`
		Email string `db:"email"`
	}
	lookup := tx.GetContext(ctx, &user, `SELECT id,email FROM users WHERE lower(normalize(btrim(email),NFC))=$1 FOR UPDATE`, ch.Email)
	if lookup != nil && !errors.Is(lookup, sql.ErrNoRows) {
		return false, lookup
	}
	switch ch.Purpose {
	case "signup":
		if lookup == nil {
			return false, nil
		}
	case "reset":
		if errors.Is(lookup, sql.ErrNoRows) {
			return false, nil
		}
		ch.UserID = &user.ID
	case "verify":
		if lookup != nil || ch.UserID == nil || *ch.UserID != user.ID {
			return false, nil
		}
	case "email_change":
		if lookup == nil {
			return false, nil
		}
		if ch.UserID == nil {
			return false, nil
		}
		// Bind the new-address proof to the exact password that was reauthenticated.
		var current string
		if err = tx.GetContext(ctx, &current, `SELECT password_hash FROM auth_password_credentials WHERE user_id=$1`, *ch.UserID); err != nil {
			return false, err
		}
		if current != ch.CredentialSnapshot {
			return false, ErrPasswordCredentialChanged
		}
	default:
		return false, ErrEmailCodeInvalid
	}
	// Delete the old challenge and encrypted delivery together. Queued jobs with
	// no outbox row become harmless no-ops, including a resend racing a worker.
	if _, err = tx.ExecContext(ctx, `DELETE FROM auth_email_challenges WHERE purpose=$1 AND email=$2`, ch.Purpose, ch.Email); err != nil {
		return false, err
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO auth_email_challenges(id,purpose,email,user_id,code_hash,password_hash,credential_snapshot,name) VALUES($1,$2,$3,$4,$5,$6,$7,$8)`, ch.ID, ch.Purpose, ch.Email, ch.UserID, ch.CodeHash, "", ch.CredentialSnapshot, ch.Name); err != nil {
		return false, err
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO auth_email_limits(purpose,email,kind) VALUES($1,$2,'send')`, ch.Purpose, ch.Email); err != nil {
		return false, err
	}
	if err = queueAuthEmailTx(ctx, tx, ch.ID, &ch.ID, ch.UserID, sealed, time.Now().Add(10*time.Minute)); err != nil {
		return false, err
	}
	if err = tx.Commit(); err != nil {
		return false, err
	}
	return true, nil
}

// CompleteEmailChallenge owns verification AND the account mutation. Its user
// lock is shared with password change, email change, session issuance, and
// deletion. A stale password/code cannot win a concurrent credential change.
func (db *DB) CompleteEmailChallenge(ctx context.Context, purpose, email, code, newHash string, hashCode func(string, string) string, notice func(string, string) (string, error)) error {
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, email); err != nil {
		return err
	}
	var wrong int
	if err = tx.GetContext(ctx, &wrong, `SELECT COUNT(*) FROM auth_email_limits WHERE purpose=$1 AND email=$2 AND kind='wrong' AND created_at>NOW()-INTERVAL '24 hours'`, purpose, email); err != nil {
		return err
	}
	if wrong >= 10 {
		return ErrEmailCodeInvalid
	}
	// Commit invalid attempts independently of challenge lifetime. Correct codes
	// also fail after the daily budget; a stranger can delay recovery, not login.
	reject := func() error {
		if _, err := tx.ExecContext(ctx, `INSERT INTO auth_email_limits(purpose,email,kind) VALUES($1,$2,'wrong')`, purpose, email); err != nil {
			return err
		}
		if err := tx.Commit(); err != nil {
			return err
		}
		return ErrEmailCodeInvalid
	}
	// Read the owner before locking the challenge to keep user→challenge lock
	// ordering consistent with account deletion and challenge creation.
	var owner *string
	if err = tx.GetContext(ctx, &owner, `SELECT user_id FROM auth_email_challenges WHERE purpose=$1 AND email=$2`, purpose, email); errors.Is(err, sql.ErrNoRows) {
		return reject()
	} else if err != nil {
		return err
	}
	var oldEmail string
	if owner != nil {
		if err = tx.GetContext(ctx, &oldEmail, `SELECT email FROM users WHERE id=$1 FOR UPDATE`, *owner); err != nil {
			return err
		}
	}
	var ch EmailChallenge
	if err = tx.GetContext(ctx, &ch, `SELECT * FROM auth_email_challenges WHERE purpose=$1 AND email=$2 FOR UPDATE`, purpose, email); err != nil {
		return err
	}
	if ch.ConsumedAt != nil || !time.Now().Before(ch.ExpiresAt) || ch.Attempts >= 5 {
		return reject()
	}
	if subtle.ConstantTimeCompare([]byte(ch.CodeHash), []byte(hashCode(ch.ID, code))) != 1 {
		if _, err = tx.ExecContext(ctx, `UPDATE auth_email_challenges SET attempts=attempts+1 WHERE id=$1`, ch.ID); err != nil {
			return err
		}
		return reject()
	}
	userID := ""
	if ch.UserID != nil {
		userID = *ch.UserID
	}
	switch purpose {
	case "signup":
		// No user is created before proof, so an attacker cannot squat an address.
		err = tx.QueryRowContext(ctx, `INSERT INTO users(email,password_hash,name,onboarding_required) VALUES($1,'',$2,FALSE) ON CONFLICT DO NOTHING RETURNING id`, email, ch.Name).Scan(&userID)
		if errors.Is(err, sql.ErrNoRows) {
			return ErrEmailCodeInvalid
		}
		if err != nil {
			return err
		}
	case "reset", "verify":
		if NormalizeLoginEmail(oldEmail) != email {
			return ErrEmailCodeInvalid
		}
	case "email_change":
		var current string
		if err = tx.GetContext(ctx, &current, `SELECT password_hash FROM auth_password_credentials WHERE user_id=$1`, userID); err != nil {
			return err
		}
		if current != ch.CredentialSnapshot {
			return ErrEmailCodeInvalid
		}
		var taken bool
		if err = tx.GetContext(ctx, &taken, `SELECT EXISTS(SELECT 1 FROM users WHERE lower(normalize(btrim(email),NFC))=$1 AND id<>$2)`, email, userID); err != nil {
			return err
		}
		if taken {
			return ErrEmailCodeInvalid
		}
		if _, err = tx.ExecContext(ctx, `UPDATE users SET email=$2 WHERE id=$1`, userID, email); err != nil {
			return err
		}
		if _, err = tx.ExecContext(ctx, `UPDATE auth_password_credentials SET email_normalized=$2 WHERE user_id=$1`, userID, email); err != nil {
			return err
		}
	default:
		return ErrEmailCodeInvalid
	}
	if purpose == "signup" || purpose == "reset" {
		if newHash == "" {
			return ErrEmailCodeInvalid
		}
		if _, err = tx.ExecContext(ctx, `INSERT INTO auth_password_credentials(user_id,email_normalized,password_hash) VALUES($1,$2,$3) ON CONFLICT(user_id) DO UPDATE SET password_hash=EXCLUDED.password_hash,email_normalized=EXCLUDED.email_normalized,failed_attempts=0,locked_until=NULL,failure_window_started_at=NULL,updated_at=NOW()`, userID, email, newHash); err != nil {
			return err
		}
		if _, err = tx.ExecContext(ctx, `UPDATE users SET password_hash='',onboarding_required=FALSE WHERE id=$1`, userID); err != nil {
			return err
		}
	}
	if purpose == "verify" {
		if _, err = tx.ExecContext(ctx, `UPDATE users SET onboarding_required=NOT EXISTS(SELECT 1 FROM auth_password_credentials WHERE user_id=$1) WHERE id=$1`, userID); err != nil {
			return err
		}
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO auth_verified_emails(user_id,email) VALUES($1,$2) ON CONFLICT(user_id) DO UPDATE SET email=EXCLUDED.email,verified_at=NOW()`, userID, email); err != nil {
		return err
	}
	if purpose == "reset" || purpose == "email_change" {
		if _, err = tx.ExecContext(ctx, `UPDATE auth_sessions SET revoked_at=COALESCE(revoked_at,NOW()) WHERE user_id=$1`, userID); err != nil {
			return err
		}
		if _, err = tx.ExecContext(ctx, `UPDATE api_keys SET active=FALSE WHERE user_id=$1`, userID); err != nil {
			return err
		}
		// Invalidate every other outstanding proof for this account. A later reset
		// to an old email or a pre-password-change email proof cannot survive.
		if _, err = tx.ExecContext(ctx, `UPDATE auth_email_challenges SET consumed_at=NOW() WHERE user_id=$1 AND consumed_at IS NULL`, userID); err != nil {
			return err
		}
		action := "password reset"
		if purpose == "email_change" {
			action = "email recovery"
		}
		sealed, err := notice(oldEmail, action)
		if err != nil {
			return err
		}
		if err = queueAuthEmailTx(ctx, tx, uuid.NewString(), nil, &userID, sealed, time.Now().Add(24*time.Hour)); err != nil {
			return err
		}
	}
	if _, err = tx.ExecContext(ctx, `UPDATE auth_email_challenges SET consumed_at=NOW(),password_hash='',credential_snapshot='' WHERE id=$1`, ch.ID); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, `DELETE FROM auth_email_outbox WHERE challenge_id=$1`, ch.ID); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO auth_events(user_id,event) VALUES($1,$2)`, userID, purpose+"_completed"); err != nil {
		return err
	}
	return tx.Commit()
}

func (db *DB) EmailForDelivery(ctx context.Context, id string) (string, error) {
	var sealed string
	err := db.GetContext(ctx, &sealed, `SELECT o.sealed FROM auth_email_outbox o LEFT JOIN auth_email_challenges c ON c.id=o.challenge_id WHERE o.id=$1 AND o.sent_at IS NULL AND o.expires_at>NOW() AND (o.challenge_id IS NULL OR (c.consumed_at IS NULL AND c.attempts<5))`, id)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return sealed, err
}
func (db *DB) MarkEmailSent(ctx context.Context, id string) error {
	_, err := db.ExecContext(ctx, `UPDATE auth_email_outbox SET sent_at=NOW(),sealed='' WHERE id=$1`, id)
	return err
}

// Failure buckets do not gate a correct password. They slow wrong guesses per
// normalized account (including unknown emails), without an email-existence oracle.
func (db *DB) RecordAuthFailure(ctx context.Context, key string) (bool, error) {
	var failures int
	err := db.QueryRowContext(ctx, `INSERT INTO auth_failure_buckets(bucket_hash) VALUES($1) ON CONFLICT(bucket_hash) DO UPDATE SET failures=CASE WHEN auth_failure_buckets.started_at<NOW()-INTERVAL '15 minutes' THEN 1 ELSE auth_failure_buckets.failures+1 END,started_at=CASE WHEN auth_failure_buckets.started_at<NOW()-INTERVAL '15 minutes' THEN NOW() ELSE auth_failure_buckets.started_at END RETURNING failures`, key).Scan(&failures)
	return failures <= 10, err
}
func (db *DB) RecordAuthEvent(ctx context.Context, userID, event string) error {
	var id any
	if userID != "" {
		id = userID
	}
	_, err := db.ExecContext(ctx, `INSERT INTO auth_events(user_id,event) VALUES($1,$2)`, id, event)
	return err
}

// Purge runs at startup and opportunistically after auth traffic, never with
// an idle polling loop. Consumed refresh rows retain their complete recovery
// lifetime; only expired tokens and already-invalid proof material are purged.
func (db *DB) PurgeAuth(ctx context.Context) error {
	for _, query := range []string{
		`DELETE FROM auth_access_tokens WHERE expires_at<NOW()`,
		`DELETE FROM auth_refresh_tokens WHERE expires_at<NOW()`,
		`DELETE FROM auth_email_challenges WHERE expires_at<NOW()-INTERVAL '1 day'`,
		`DELETE FROM auth_email_outbox WHERE expires_at<NOW() OR sent_at<NOW()-INTERVAL '1 day'`,
		`DELETE FROM auth_failure_buckets WHERE started_at<NOW()-INTERVAL '1 day'`,
		`DELETE FROM auth_email_limits WHERE created_at<NOW()-INTERVAL '24 hours'`,
		`DELETE FROM auth_events WHERE created_at<NOW()-INTERVAL '90 days'`,
	} {
		if _, err := db.ExecContext(ctx, query); err != nil {
			return err
		}
	}
	return nil
}

func (db *DB) PasswordCredentialForUser(ctx context.Context, userID string) (*PasswordCredential, error) {
	var row PasswordCredential
	err := db.GetContext(ctx, &row, `SELECT * FROM auth_password_credentials WHERE user_id=$1`, userID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrPasswordCredentialInvalid
	}
	return &row, err
}

func (db *DB) EmailVerified(ctx context.Context, userID string) (bool, error) {
	var verified bool
	err := db.GetContext(ctx, &verified, `SELECT EXISTS(SELECT 1 FROM auth_verified_emails v JOIN users u ON u.id=v.user_id WHERE u.id=$1 AND v.email=lower(normalize(btrim(u.email),NFC)))`, userID)
	return verified, err
}
