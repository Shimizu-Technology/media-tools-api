package database

import (
	"context"
	"errors"
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

func TestRecoveryCodeConcurrentRedemption(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := insertPasskeyTestUser(t, db)
	codes, err := db.ReplaceRecoveryCodes(ctx, userID)
	if err != nil {
		t.Fatal(err)
	}
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
			codes, err := db.ReplaceRecoveryCodes(ctx, userID)
			if err != nil {
				t.Fatal(err)
			}
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
			codes, err := db.ReplaceRecoveryCodes(ctx, userID)
			if err != nil {
				t.Fatal(err)
			}
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

func TestRecoveryCodeReplayedSuccessorDoesNotConsumeCode(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := insertPasskeyTestUser(t, db)
	existing, err := db.CreateFirstPartySession(ctx, userID, "web", "Existing browser")
	if err != nil {
		t.Fatal(err)
	}
	codes, err := db.ReplaceRecoveryCodes(ctx, userID)
	if err != nil {
		t.Fatal(err)
	}
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
