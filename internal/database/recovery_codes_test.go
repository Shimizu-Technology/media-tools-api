package database

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestRecoveryCodeFormatting(t *testing.T) {
	code, hash, err := newRecoveryCode()
	if err != nil {
		t.Fatal(err)
	}
	if got, valid := parseRecoveryCode("  " + strings.ToLower(code) + "  "); !valid || got != hash {
		t.Fatal("formatted code could not be recovered")
	}
	for _, invalid := range []string{"", "MTR-INVALID", strings.ReplaceAll(code, "MTR-", ""), code + "A"} {
		if _, valid := parseRecoveryCode(invalid); valid {
			t.Fatalf("accepted invalid code %q", invalid)
		}
	}
}

func activateRecoveryCodes(t *testing.T, db *DB, userID string) []string {
	t.Helper()
	rotation, err := db.BeginRecoveryCodeRotation(context.Background(), userID)
	if err != nil {
		t.Fatal(err)
	}
	if count, err := db.ConfirmRecoveryCodeRotation(context.Background(), userID, rotation.ID); err != nil || count != recoveryCodeCount {
		t.Fatalf("confirm recovery codes = %d, %v", count, err)
	}
	return rotation.Codes
}

func TestRecoveryCodeConcurrentRedemption(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := insertPasskeyTestUser(t, db)
	codes := activateRecoveryCodes(t, db, userID)
	next, err := RandomFirstPartyRefreshToken()
	if err != nil {
		t.Fatal(err)
	}
	type result struct {
		pair *AuthTokenPair
		err  error
	}
	results := make(chan result, 2)
	start := make(chan struct{})
	var workers sync.WaitGroup
	for i := 0; i < 2; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			<-start
			pair, err := db.RedeemRecoveryCode(ctx, codes[0], "ios", "Replacement phone", next)
			results <- result{pair: pair, err: err}
		}()
	}
	close(start)
	workers.Wait()
	close(results)
	var pairs []*AuthTokenPair
	for result := range results {
		if result.err != nil {
			t.Fatal(result.err)
		}
		pairs = append(pairs, result.pair)
	}
	if len(pairs) != 2 || pairs[0].SessionID != pairs[1].SessionID ||
		pairs[0].RefreshToken != next || pairs[1].RefreshToken != next ||
		pairs[0].AccessToken == pairs[1].AccessToken {
		t.Fatalf("concurrent exact retry did not recover one session: %#v", pairs)
	}
	wrong, err := RandomFirstPartyRefreshToken()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.RedeemRecoveryCode(ctx, codes[0], "ios", "Replacement phone", wrong); !errors.Is(err, ErrRecoveryCodeInvalid) {
		t.Fatalf("wrong successor retry = %v", err)
	}
}

func TestRecoveryCodeExactRetryExpiresAndHonorsSessionRevocation(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	for _, mode := range []string{"expired", "revoked"} {
		t.Run(mode, func(t *testing.T) {
			userID := insertPasskeyTestUser(t, db)
			codes := activateRecoveryCodes(t, db, userID)
			next, err := RandomFirstPartyRefreshToken()
			if err != nil {
				t.Fatal(err)
			}
			pair, err := db.RedeemRecoveryCode(ctx, codes[0], "android", "Tablet", next)
			if err != nil {
				t.Fatal(err)
			}
			hash, _ := parseRecoveryCode(codes[0])
			if mode == "expired" {
				if _, err := db.ExecContext(ctx, `UPDATE auth_recovery_codes SET consumed_at = $2 WHERE code_hash = $1`, hash, time.Now().UTC().Add(-credentialIssuanceRetryWindow-time.Second)); err != nil {
					t.Fatal(err)
				}
			} else if revoked, err := db.RevokeFirstPartySession(ctx, userID, pair.SessionID); err != nil || !revoked {
				t.Fatalf("revoke session = %v, %v", revoked, err)
			}
			if _, err := db.RedeemRecoveryCode(ctx, codes[0], "android", "Tablet", next); !errors.Is(err, ErrRecoveryCodeInvalid) {
				t.Fatalf("retry after %s = %v", mode, err)
			}
		})
	}
}

func TestRecoveryCodeExactRetryRejectsSpentOrExpiredSuccessor(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	for _, mode := range []string{"spent", "expired"} {
		t.Run(mode, func(t *testing.T) {
			userID := insertPasskeyTestUser(t, db)
			codes := activateRecoveryCodes(t, db, userID)
			next, err := RandomFirstPartyRefreshToken()
			if err != nil {
				t.Fatal(err)
			}
			pair, err := db.RedeemRecoveryCode(ctx, codes[0], "ios", "Phone", next)
			if err != nil {
				t.Fatal(err)
			}
			if mode == "spent" {
				after, err := RandomFirstPartyRefreshToken()
				if err != nil {
					t.Fatal(err)
				}
				if _, err := db.RefreshFirstPartySessionWithSuccessor(ctx, next, after); err != nil {
					t.Fatal(err)
				}
			} else {
				hash, _ := authTokenHash(next, "mta_rt_")
				if _, err := db.ExecContext(ctx, `UPDATE auth_refresh_tokens SET expires_at = NOW() - INTERVAL '1 second' WHERE token_hash = $1`, hash); err != nil {
					t.Fatal(err)
				}
			}
			var accessBefore int
			if err := db.GetContext(ctx, &accessBefore, `SELECT COUNT(*) FROM auth_access_tokens WHERE session_id = $1`, pair.SessionID); err != nil {
				t.Fatal(err)
			}
			if _, err := db.RedeemRecoveryCode(ctx, codes[0], "ios", "Phone", next); !errors.Is(err, ErrRecoveryCodeInvalid) {
				t.Fatalf("%s successor retry = %v", mode, err)
			}
			var accessAfter int
			if err := db.GetContext(ctx, &accessAfter, `SELECT COUNT(*) FROM auth_access_tokens WHERE session_id = $1`, pair.SessionID); err != nil || accessAfter != accessBefore {
				t.Fatalf("%s successor minted access: before=%d after=%d err=%v", mode, accessBefore, accessAfter, err)
			}
		})
	}
}

func TestWebRecoveryCodeAccountSwitchIsAtomicAndRecoversLostResponse(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	oldUserID := insertPasskeyTestUser(t, db)
	targetUserID := insertPasskeyTestUser(t, db)
	oldSession, err := db.CreateFirstPartySession(ctx, oldUserID, "web", "Old browser")
	if err != nil {
		t.Fatal(err)
	}
	codes := activateRecoveryCodes(t, db, targetUserID)
	successor, _ := RandomFirstPartyRefreshToken()
	pair, err := db.RedeemWebRecoveryCode(ctx, codes[0], successor, []string{oldSession.RefreshToken})
	if err != nil {
		t.Fatal(err)
	}
	if pair.UserID != targetUserID || pair.RefreshToken != successor {
		t.Fatalf("recovered wrong account: %#v", pair)
	}
	if _, _, err := db.GetUserByFirstPartyAccessToken(ctx, oldSession.AccessToken); !errors.Is(err, ErrSessionInvalid) {
		t.Fatalf("old browser session remained active: %v", err)
	}
	retried, err := db.RedeemWebRecoveryCode(ctx, "", successor, []string{oldSession.RefreshToken})
	if err != nil {
		t.Fatal(err)
	}
	if retried.SessionID != pair.SessionID || retried.RefreshToken != successor || retried.AccessToken == pair.AccessToken {
		t.Fatalf("lost-response retry did not recover exact session: first=%#v retry=%#v", pair, retried)
	}
	var sessions int
	if err := db.GetContext(ctx, &sessions, `SELECT COUNT(*) FROM auth_sessions WHERE user_id = $1 AND client_type = 'web'`, targetUserID); err != nil || sessions != 1 {
		t.Fatalf("target web sessions = %d, %v", sessions, err)
	}

	stillActive, err := db.CreateFirstPartySession(ctx, oldUserID, "web", "Preserved browser")
	if err != nil {
		t.Fatal(err)
	}
	wrongSuccessor, _ := RandomFirstPartyRefreshToken()
	if _, err := db.RedeemWebRecoveryCode(ctx, codes[0], wrongSuccessor, []string{stillActive.RefreshToken}); !errors.Is(err, ErrRecoveryCodeInvalid) {
		t.Fatalf("used code with another successor = %v", err)
	}
	if user, _, err := db.GetUserByFirstPartyAccessToken(ctx, stillActive.AccessToken); err != nil || user.ID != oldUserID {
		t.Fatalf("failed redemption revoked old browser: user=%#v err=%v", user, err)
	}
}

func TestWebRecoveryCodeRevocationFailureRollsBackRedemption(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	oldUserID := insertPasskeyTestUser(t, db)
	targetUserID := insertPasskeyTestUser(t, db)
	oldSession, err := db.CreateFirstPartySession(ctx, oldUserID, "web", "Old browser")
	if err != nil {
		t.Fatal(err)
	}
	codes := activateRecoveryCodes(t, db, targetUserID)
	successor, _ := RandomFirstPartyRefreshToken()
	functionName := "fail_web_recovery_revoke_fn"
	triggerName := "fail_web_recovery_revoke"
	t.Cleanup(func() {
		_, _ = db.ExecContext(context.Background(), `DROP TRIGGER IF EXISTS fail_web_recovery_revoke ON auth_sessions`)
		_, _ = db.ExecContext(context.Background(), `DROP FUNCTION IF EXISTS fail_web_recovery_revoke_fn()`)
	})
	if _, err := db.ExecContext(ctx, `
		CREATE FUNCTION fail_web_recovery_revoke_fn() RETURNS trigger AS $$
		BEGIN
			IF OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL THEN RAISE EXCEPTION 'injected revoke failure'; END IF;
			RETURN NEW;
		END; $$ LANGUAGE plpgsql`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `CREATE TRIGGER `+triggerName+` BEFORE UPDATE ON auth_sessions FOR EACH ROW EXECUTE FUNCTION `+functionName+`()`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.RedeemWebRecoveryCode(ctx, codes[0], successor, []string{oldSession.RefreshToken}); err == nil || errors.Is(err, ErrRecoveryCodeInvalid) {
		t.Fatalf("injected revoke failure = %v", err)
	}
	if user, _, err := db.GetUserByFirstPartyAccessToken(ctx, oldSession.AccessToken); err != nil || user.ID != oldUserID {
		t.Fatalf("rollback revoked old session: user=%#v err=%v", user, err)
	}
	if remaining, err := db.RemainingRecoveryCodes(ctx, targetUserID); err != nil || remaining != recoveryCodeCount {
		t.Fatalf("rollback consumed code: remaining=%d err=%v", remaining, err)
	}
	var targetSessions int
	if err := db.GetContext(ctx, &targetSessions, `SELECT COUNT(*) FROM auth_sessions WHERE user_id = $1`, targetUserID); err != nil || targetSessions != 0 {
		t.Fatalf("rollback left target session: count=%d err=%v", targetSessions, err)
	}
	if _, err := db.ExecContext(ctx, `DROP TRIGGER `+triggerName+` ON auth_sessions`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `DROP FUNCTION `+functionName+`()`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.RedeemWebRecoveryCode(ctx, codes[0], successor, []string{oldSession.RefreshToken}); err != nil {
		t.Fatalf("redemption after rollback = %v", err)
	}
}

func TestWebRecoveryCodeConcurrentExactRetryCreatesOneSession(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := insertPasskeyTestUser(t, db)
	codes := activateRecoveryCodes(t, db, userID)
	successor, _ := RandomFirstPartyRefreshToken()
	type result struct {
		pair *AuthTokenPair
		err  error
	}
	results := make(chan result, 2)
	start := make(chan struct{})
	var workers sync.WaitGroup
	for i := 0; i < 2; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			<-start
			pair, err := db.RedeemWebRecoveryCode(ctx, codes[0], successor, nil)
			results <- result{pair, err}
		}()
	}
	close(start)
	workers.Wait()
	close(results)
	var first *AuthTokenPair
	for result := range results {
		if result.err != nil {
			t.Fatal(result.err)
		}
		if first == nil {
			first = result.pair
			continue
		}
		if result.pair.SessionID != first.SessionID || result.pair.AccessToken == first.AccessToken {
			t.Fatalf("concurrent results = %#v %#v", first, result.pair)
		}
	}
	var sessions int
	if err := db.GetContext(ctx, &sessions, `SELECT COUNT(*) FROM auth_sessions WHERE user_id = $1 AND client_type = 'web'`, userID); err != nil || sessions != 1 {
		t.Fatalf("concurrent web sessions = %d, %v", sessions, err)
	}
}

func TestWebRecoveryCodeStaleSuccessorCanBeReplacedWithoutBurningAnotherCode(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := insertPasskeyTestUser(t, db)
	codes := activateRecoveryCodes(t, db, userID)
	stale, _ := RandomFirstPartyRefreshToken()
	if _, err := db.RedeemWebRecoveryCode(ctx, codes[0], stale, nil); err != nil {
		t.Fatal(err)
	}
	staleHash, _ := parseRecoveryCode(codes[0])
	if _, err := db.ExecContext(ctx, `UPDATE auth_recovery_codes SET consumed_at = $2 WHERE code_hash = $1`, staleHash, time.Now().UTC().Add(-credentialIssuanceRetryWindow-time.Second)); err != nil {
		t.Fatal(err)
	}
	if _, err := db.RedeemWebRecoveryCode(ctx, "", stale, nil); !errors.Is(err, ErrInvalidSuccessorToken) {
		t.Fatalf("stale successor recovery = %v", err)
	}
	fresh, _ := RandomFirstPartyRefreshToken()
	if _, err := db.RedeemWebRecoveryCode(ctx, codes[1], fresh, nil); err != nil {
		t.Fatalf("fresh successor could not redeem unused code: %v", err)
	}
}

func TestWebRecoveryCodeWrongCodeKeepsSuccessorUsable(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := insertPasskeyTestUser(t, db)
	codes := activateRecoveryCodes(t, db, userID)
	successor, _ := RandomFirstPartyRefreshToken()
	if _, err := db.RedeemWebRecoveryCode(ctx, "MTR-INVALID", successor, nil); !errors.Is(err, ErrRecoveryCodeInvalid) {
		t.Fatalf("wrong code = %v", err)
	}
	if _, err := db.RedeemWebRecoveryCode(ctx, codes[0], successor, nil); err != nil {
		t.Fatalf("wrong code poisoned prepared successor: %v", err)
	}
}

func TestWebRecoveryCodeUnavailableSuccessorDoesNotConsumeCode(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := insertPasskeyTestUser(t, db)
	codes := activateRecoveryCodes(t, db, userID)
	occupied, err := db.CreateFirstPartySession(ctx, userID, "web", "Occupied successor")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.RedeemWebRecoveryCode(ctx, "", occupied.RefreshToken, nil); !errors.Is(err, ErrInvalidSuccessorToken) {
		t.Fatalf("occupied empty recovery successor = %v", err)
	}
	if _, err := db.RedeemWebRecoveryCode(ctx, codes[0], occupied.RefreshToken, nil); !errors.Is(err, ErrInvalidSuccessorToken) {
		t.Fatalf("occupied successor = %v", err)
	}
	if remaining, err := db.RemainingRecoveryCodes(ctx, userID); err != nil || remaining != recoveryCodeCount {
		t.Fatalf("occupied successor consumed code: remaining=%d err=%v", remaining, err)
	}
	fresh, _ := RandomFirstPartyRefreshToken()
	if _, err := db.RedeemWebRecoveryCode(ctx, codes[0], fresh, []string{occupied.RefreshToken}); err != nil {
		t.Fatalf("same code failed with fresh successor: %v", err)
	}
}

func TestRecoveryCodeReplayedSuccessorDoesNotConsumeCode(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := insertPasskeyTestUser(t, db)
	existing, err := db.CreateFirstPartySession(ctx, userID, "web", "Existing browser")
	if err != nil {
		t.Fatal(err)
	}
	codes := activateRecoveryCodes(t, db, userID)
	if _, err := db.RedeemRecoveryCode(ctx, codes[0], "web", "New browser", existing.RefreshToken); !errors.Is(err, ErrRecoveryCodeInvalid) {
		t.Fatalf("replayed successor = %v", err)
	}
	if remaining, err := db.RemainingRecoveryCodes(ctx, userID); err != nil || remaining != recoveryCodeCount {
		t.Fatalf("replayed successor consumed code: remaining=%d err=%v", remaining, err)
	}
	var sessions int
	if err := db.GetContext(ctx, &sessions, `SELECT COUNT(*) FROM auth_sessions WHERE user_id = $1`, userID); err != nil || sessions != 1 {
		t.Fatalf("replayed successor created session: count=%d err=%v", sessions, err)
	}
}

func TestRecoveryCodeRotationPreservesOldSetUntilConfirmAndRecoversLostResponses(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := insertPasskeyTestUser(t, db)
	oldCodes := activateRecoveryCodes(t, db, userID)

	lost, err := db.BeginRecoveryCodeRotation(ctx, userID)
	if err != nil {
		t.Fatal(err)
	}
	replacement, err := db.BeginRecoveryCodeRotation(ctx, userID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.ConfirmRecoveryCodeRotation(ctx, userID, lost.ID); !errors.Is(err, ErrRecoveryRotationInvalid) {
		t.Fatalf("discarded lost begin remained confirmable: %v", err)
	}
	if count, err := db.RemainingRecoveryCodes(ctx, userID); err != nil || count != recoveryCodeCount {
		t.Fatalf("begin changed active count = %d, %v", count, err)
	}
	for _, pendingCode := range []string{lost.Codes[0], replacement.Codes[0]} {
		next, _ := RandomFirstPartyRefreshToken()
		if _, err := db.RedeemRecoveryCode(ctx, pendingCode, "ios", "Phone", next); !errors.Is(err, ErrRecoveryCodeInvalid) {
			t.Fatalf("pending code redeemed before confirmation: %v", err)
		}
	}
	oldNext, _ := RandomFirstPartyRefreshToken()
	if _, err := db.RedeemRecoveryCode(ctx, oldCodes[0], "ios", "Phone", oldNext); err != nil {
		t.Fatalf("old code stopped working before confirmation: %v", err)
	}
	if count, err := db.ConfirmRecoveryCodeRotation(ctx, userID, replacement.ID); err != nil || count != recoveryCodeCount {
		t.Fatalf("confirm replacement = %d, %v", count, err)
	}
	if count, err := db.ConfirmRecoveryCodeRotation(ctx, userID, replacement.ID); err != nil || count != recoveryCodeCount {
		t.Fatalf("lost confirm retry = %d, %v", count, err)
	}
	oldNext, _ = RandomFirstPartyRefreshToken()
	if _, err := db.RedeemRecoveryCode(ctx, oldCodes[1], "ios", "Phone", oldNext); !errors.Is(err, ErrRecoveryCodeInvalid) {
		t.Fatalf("old code remained active after confirmation: %v", err)
	}
	newNext, _ := RandomFirstPartyRefreshToken()
	if _, err := db.RedeemRecoveryCode(ctx, replacement.Codes[0], "ios", "Phone", newNext); err != nil {
		t.Fatalf("confirmed code did not redeem: %v", err)
	}
	if count, err := db.ConfirmRecoveryCodeRotation(ctx, userID, replacement.ID); err != nil || count != recoveryCodeCount-1 {
		t.Fatalf("idempotent confirm after redemption = %d, %v", count, err)
	}

	newer, err := db.BeginRecoveryCodeRotation(ctx, userID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.ConfirmRecoveryCodeRotation(ctx, userID, newer.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ConfirmRecoveryCodeRotation(ctx, userID, replacement.ID); !errors.Is(err, ErrRecoveryRotationInvalid) {
		t.Fatalf("superseded confirmed rotation reported success: %v", err)
	}
}

func TestRecoveryCodeRotationRejectsForeignAndExpiredPendingSet(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	ownerID := insertPasskeyTestUser(t, db)
	otherID := insertPasskeyTestUser(t, db)
	oldCodes := activateRecoveryCodes(t, db, ownerID)
	pending, err := db.BeginRecoveryCodeRotation(ctx, ownerID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.ConfirmRecoveryCodeRotation(ctx, otherID, pending.ID); !errors.Is(err, ErrRecoveryRotationInvalid) {
		t.Fatalf("other user confirmed rotation: %v", err)
	}
	if _, err := db.ExecContext(ctx, `UPDATE auth_recovery_code_rotations SET expires_at = NOW() - INTERVAL '1 second' WHERE id = $1`, pending.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ConfirmRecoveryCodeRotation(ctx, ownerID, pending.ID); !errors.Is(err, ErrRecoveryRotationInvalid) {
		t.Fatalf("expired rotation confirmed: %v", err)
	}
	if count, err := db.RemainingRecoveryCodes(ctx, ownerID); err != nil || count != recoveryCodeCount {
		t.Fatalf("expired pending set changed active count = %d, %v", count, err)
	}
	oldNext, _ := RandomFirstPartyRefreshToken()
	if _, err := db.RedeemRecoveryCode(ctx, oldCodes[0], "android", "Tablet", oldNext); err != nil {
		t.Fatalf("expired rotation invalidated old set: %v", err)
	}
	pendingNext, _ := RandomFirstPartyRefreshToken()
	if _, err := db.RedeemRecoveryCode(ctx, pending.Codes[0], "android", "Tablet", pendingNext); !errors.Is(err, ErrRecoveryCodeInvalid) {
		t.Fatalf("expired pending code became active: %v", err)
	}
}

func TestRecoveryCodeRotationConfirmationRollsBackAtomically(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := insertPasskeyTestUser(t, db)
	oldCodes := activateRecoveryCodes(t, db, userID)
	pending, err := db.BeginRecoveryCodeRotation(ctx, userID)
	if err != nil {
		t.Fatal(err)
	}
	triggerName := "fail_recovery_activation"
	functionName := "fail_recovery_activation_fn"
	t.Cleanup(func() {
		_, _ = db.ExecContext(context.Background(), `DROP TRIGGER IF EXISTS fail_recovery_activation ON auth_recovery_codes`)
		_, _ = db.ExecContext(context.Background(), `DROP FUNCTION IF EXISTS fail_recovery_activation_fn()`)
	})
	if _, err := db.ExecContext(ctx, `
		CREATE FUNCTION fail_recovery_activation_fn() RETURNS trigger AS $$
		BEGIN
			IF NEW.active AND NOT OLD.active THEN RAISE EXCEPTION 'injected activation failure'; END IF;
			RETURN NEW;
		END; $$ LANGUAGE plpgsql`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `CREATE TRIGGER `+triggerName+` BEFORE UPDATE ON auth_recovery_codes FOR EACH ROW EXECUTE FUNCTION `+functionName+`()`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ConfirmRecoveryCodeRotation(ctx, userID, pending.ID); err == nil || errors.Is(err, ErrRecoveryRotationInvalid) {
		t.Fatalf("injected confirmation failure = %v", err)
	}
	if count, err := db.RemainingRecoveryCodes(ctx, userID); err != nil || count != recoveryCodeCount {
		t.Fatalf("rollback lost active set = %d, %v", count, err)
	}
	oldNext, _ := RandomFirstPartyRefreshToken()
	if _, err := db.RedeemRecoveryCode(ctx, oldCodes[0], "ios", "Phone", oldNext); err != nil {
		t.Fatalf("old code failed after rollback: %v", err)
	}
	var pendingActive int
	if err := db.GetContext(ctx, &pendingActive, `SELECT COUNT(*) FROM auth_recovery_codes WHERE rotation_id = $1 AND active`, pending.ID); err != nil || pendingActive != 0 {
		t.Fatalf("rollback activated pending set = %d, %v", pendingActive, err)
	}
	if _, err := db.ExecContext(ctx, `DROP TRIGGER `+triggerName+` ON auth_recovery_codes`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `DROP FUNCTION `+functionName+`()`); err != nil {
		t.Fatal(err)
	}
	if count, err := db.ConfirmRecoveryCodeRotation(ctx, userID, pending.ID); err != nil || count != recoveryCodeCount {
		t.Fatalf("confirmation after rollback = %d, %v", count, err)
	}
}

func TestRecoveryCodeRotationSerializesConfirmRedeemAndBegin(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := insertPasskeyTestUser(t, db)
	oldCodes := activateRecoveryCodes(t, db, userID)
	pending, err := db.BeginRecoveryCodeRotation(ctx, userID)
	if err != nil {
		t.Fatal(err)
	}
	start := make(chan struct{})
	errs := make(chan error, 3)
	var workers sync.WaitGroup
	workers.Add(3)
	go func() {
		defer workers.Done()
		<-start
		_, err := db.ConfirmRecoveryCodeRotation(ctx, userID, pending.ID)
		if err != nil && !errors.Is(err, ErrRecoveryRotationInvalid) {
			errs <- err
			return
		}
		errs <- nil
	}()
	go func() {
		defer workers.Done()
		<-start
		next, _ := RandomFirstPartyRefreshToken()
		_, err := db.RedeemRecoveryCode(ctx, oldCodes[0], "ios", "Phone", next)
		if err != nil && !errors.Is(err, ErrRecoveryCodeInvalid) {
			errs <- err
			return
		}
		errs <- nil
	}()
	go func() {
		defer workers.Done()
		<-start
		_, err := db.BeginRecoveryCodeRotation(ctx, userID)
		errs <- err
	}()
	close(start)
	workers.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	if count, err := db.RemainingRecoveryCodes(ctx, userID); err != nil || (count != recoveryCodeCount && count != recoveryCodeCount-1) {
		t.Fatalf("serialized active count = %d, %v", count, err)
	}
	var pendingRotations, pendingCodes int
	if err := db.GetContext(ctx, &pendingRotations, `SELECT COUNT(*) FROM auth_recovery_code_rotations WHERE user_id = $1 AND confirmed_at IS NULL`, userID); err != nil {
		t.Fatal(err)
	}
	if err := db.GetContext(ctx, &pendingCodes, `SELECT COUNT(*) FROM auth_recovery_codes WHERE user_id = $1 AND NOT active`, userID); err != nil {
		t.Fatal(err)
	}
	if pendingRotations != 1 || pendingCodes != recoveryCodeCount {
		t.Fatalf("serialized pending state: rotations=%d codes=%d", pendingRotations, pendingCodes)
	}
}

func TestRecoveryCodeRotationMigrationDownAndUp(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	tx, err := db.BeginTxx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()

	readMigration := func(name string) string {
		t.Helper()
		contents, err := os.ReadFile(filepath.Join("..", "..", "migrations", name))
		if err != nil {
			t.Fatal(err)
		}
		return string(contents)
	}
	objectExists := func(query string, args ...any) bool {
		t.Helper()
		var exists bool
		if err := tx.GetContext(ctx, &exists, query, args...); err != nil {
			t.Fatal(err)
		}
		return exists
	}

	if _, err := tx.ExecContext(ctx, readMigration("049_two_phase_recovery_code_rotation.down.sql")); err != nil {
		t.Fatalf("apply migration 049 down: %v", err)
	}
	if objectExists(`SELECT to_regclass('auth_recovery_code_rotations') IS NOT NULL`) {
		t.Fatal("rotation table remained after down migration")
	}
	if objectExists(`SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'auth_recovery_codes' AND column_name IN ('rotation_id', 'active'))`) {
		t.Fatal("rotation columns remained after down migration")
	}
	if !objectExists(`SELECT to_regclass('auth_recovery_codes_user_id_idx') IS NOT NULL`) || objectExists(`SELECT to_regclass('auth_recovery_codes_user_active_idx') IS NOT NULL`) {
		t.Fatal("down migration did not restore the legacy recovery-code index")
	}

	if _, err := tx.ExecContext(ctx, readMigration("049_two_phase_recovery_code_rotation.up.sql")); err != nil {
		t.Fatalf("apply migration 049 up: %v", err)
	}
	if !objectExists(`SELECT to_regclass('auth_recovery_code_rotations') IS NOT NULL`) {
		t.Fatal("rotation table missing after up migration")
	}
	var columns int
	if err := tx.GetContext(ctx, &columns, `SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'auth_recovery_codes' AND column_name IN ('rotation_id', 'active')`); err != nil || columns != 2 {
		t.Fatalf("rotation columns after up = %d, %v", columns, err)
	}
	if !objectExists(`SELECT to_regclass('auth_recovery_codes_user_active_idx') IS NOT NULL`) || objectExists(`SELECT to_regclass('auth_recovery_codes_user_id_idx') IS NOT NULL`) {
		t.Fatal("up migration did not install only the active recovery-code index")
	}
}
