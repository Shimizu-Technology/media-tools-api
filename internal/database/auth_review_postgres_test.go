package database

import (
	"context"
	"errors"
	emailservice "github.com/Shimizu-Technology/media-tools-api/internal/services/email"
	"github.com/google/uuid"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestEmailRollingBudgetsSurviveChallengeReplacement(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	service, _ := emailservice.New("log", "", "", "synthetic-limit-secret")
	userID := createPasswordTestUser(t, db)
	var address string
	if err := db.Get(&address, `SELECT email FROM users WHERE id=$1`, userID); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.Exec(`DELETE FROM auth_email_limits WHERE email=$1`, address) })
	issue := func(purpose string) bool {
		id := uuid.NewString()
		sealed, _ := service.Seal(emailservice.CodeMessage(address, "456789", purpose))
		yes, err := db.IssueEmailChallenge(ctx, EmailChallenge{ID: id, Purpose: purpose, Email: address, UserID: &userID, CodeHash: service.CodeHash(id, "456789")}, sealed)
		if err != nil {
			t.Fatal(err)
		}
		return yes
	}
	complete := func(purpose, code string) error {
		return db.CompleteEmailChallenge(ctx, purpose, address, code, "synthetic-new-encoded-password-hash", service.CodeHash, func(to, action string) (string, error) { return service.Seal(emailservice.Notice(to, action)) })
	}
	// Two exhausted challenges consume the shared daily guessing budget.
	for ch := 0; ch < 2; ch++ {
		if !issue("reset") {
			t.Fatal("eligible reset suppressed")
		}
		for i := 0; i < 5; i++ {
			if !errors.Is(complete("reset", "000000"), ErrEmailCodeInvalid) {
				t.Fatal("wrong code accepted")
			}
		}
		if _, err := db.Exec(`UPDATE auth_email_limits SET created_at=created_at-INTERVAL '20 minutes' WHERE email=$1 AND kind='send'`, address); err != nil {
			t.Fatal(err)
		}
	}
	if !issue("reset") {
		t.Fatal("third challenge suppressed")
	}
	if !errors.Is(complete("reset", "456789"), ErrEmailCodeInvalid) {
		t.Fatal("new challenge reset daily guesses")
	}
	// Purge/restart does not clear live history; purpose budgets are separate.
	if err := db.PurgeAuth(ctx); err != nil {
		t.Fatal(err)
	}
	if !errors.Is(complete("reset", "456789"), ErrEmailCodeInvalid) {
		t.Fatal("purge reset daily guesses")
	}
	if !issue("verify") {
		t.Fatal("reset budget leaked to verify")
	}
	if err := complete("verify", "456789"); err != nil {
		t.Fatal("separate purpose rejected", err)
	}
	// Only entries in the rolling window count, rather than UTC calendar days.
	if _, err := db.Exec(`UPDATE auth_email_limits SET created_at=NOW()-INTERVAL '24 hours 1 second' WHERE email=$1 AND kind='wrong'`, address); err != nil {
		t.Fatal(err)
	}
	if err := complete("reset", "456789"); err != nil {
		t.Fatal("rolling guessing window did not reopen", err)
	}
}

func TestEmailSendCapIncreasingDelayAndConcurrency(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	address := uuid.NewString() + "@example.invalid"
	t.Cleanup(func() {
		_, _ = db.Exec(`DELETE FROM auth_email_challenges WHERE email=$1`, address)
		_, _ = db.Exec(`DELETE FROM auth_email_limits WHERE email=$1`, address)
	})
	issue := func() (bool, error) {
		id := uuid.NewString()
		return db.IssueEmailChallenge(ctx, EmailChallenge{ID: id, Email: address, Purpose: "signup", CodeHash: strings.Repeat("a", 64)}, "synthetic-sealed")
	}
	if yes, err := issue(); err != nil || !yes {
		t.Fatal("first send", err)
	}
	if yes, err := issue(); err != nil || yes {
		t.Fatal("immediate resend not suppressed", err)
	}
	if _, err := db.Exec(`UPDATE auth_email_limits SET created_at=NOW()-INTERVAL '61 seconds' WHERE email=$1`, address); err != nil {
		t.Fatal(err)
	}
	if yes, err := issue(); err != nil || !yes {
		t.Fatal("second send", err)
	}
	if _, err := db.Exec(`UPDATE auth_email_limits SET created_at=NOW()-INTERVAL '61 seconds' WHERE email=$1`, address); err != nil {
		t.Fatal(err)
	}
	if yes, err := issue(); err != nil || yes {
		t.Fatal("resend delay did not increase", err)
	}
	for i := 0; i < 2; i++ {
		if _, err := db.Exec(`UPDATE auth_email_limits SET created_at=created_at-INTERVAL '20 minutes' WHERE email=$1`, address); err != nil {
			t.Fatal(err)
		}
		if yes, err := issue(); err != nil || !yes {
			t.Fatal("send under cap", err)
		}
	}
	if _, err := db.Exec(`UPDATE auth_email_limits SET created_at=created_at-INTERVAL '20 minutes' WHERE email=$1`, address); err != nil {
		t.Fatal(err)
	}
	var admitted atomic.Int32
	var wg sync.WaitGroup
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			yes, err := issue()
			if err != nil {
				t.Error(err)
			}
			if yes {
				admitted.Add(1)
			}
		}()
	}
	wg.Wait()
	if admitted.Load() != 1 {
		t.Fatalf("daily send cap race admitted %d", admitted.Load())
	}
	if _, err := db.Exec(`UPDATE auth_email_limits SET created_at=created_at-INTERVAL '1 hour' WHERE email=$1`, address); err != nil {
		t.Fatal(err)
	}
	if yes, err := issue(); err != nil || yes {
		t.Fatal("sixth send admitted", err)
	}
	if _, err := db.Exec(`UPDATE auth_email_limits SET created_at=$2 WHERE email=$1`, address, time.Now().Add(-24*time.Hour-time.Second)); err != nil {
		t.Fatal(err)
	}
	if yes, err := issue(); err != nil || !yes {
		t.Fatal("rolling send window did not reopen", err)
	}
}

func TestUsageExemptionRequiresExactOwnerIdentity(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := createPasswordTestUser(t, db)
	var keyID string
	if err := db.QueryRow(`INSERT INTO api_keys(user_id,key_hash,key_prefix,name) VALUES($1,$2,'same-prefix','Synthetic owner collision') RETURNING id`, userID, uuid.NewString()).Scan(&keyID); err != nil {
		t.Fatal(err)
	}
	for _, owner := range []struct {
		user, key string
		exempt    bool
	}{{"", uuid.NewString(), false}, {"", "", false}, {"", keyID, true}, {userID, "", true}} {
		if err := db.EnsureUsagePolicy(ctx, userID, 1, 1, owner.user, owner.key); err != nil {
			t.Fatal(err)
		}
		usage, err := db.AccountUsage(ctx, userID)
		if err != nil || usage.Exempt != owner.exempt {
			t.Fatal("owner exemption did not require exact identity", err)
		}
	}
}

func TestRefreshReuseAfterSuccessorConsumptionRevokesBothClientFlows(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := createPasswordTestUser(t, db)
	for _, client := range []string{"ios", "web"} {
		t.Run(client, func(t *testing.T) {
			pair, err := db.CreateFirstPartySession(ctx, userID, client, "Synthetic device")
			if err != nil {
				t.Fatal(err)
			}
			next := ""
			if client == "ios" {
				next, _ = RandomFirstPartyRefreshToken()
			}
			rotated, err := db.RefreshFirstPartySessionWithSuccessor(ctx, pair.RefreshToken, next)
			if err != nil {
				t.Fatal(err)
			}
			if client == "ios" {
				recovered, err := db.RefreshFirstPartySessionWithSuccessor(ctx, pair.RefreshToken, next)
				if err != nil || recovered.RefreshToken != next {
					t.Fatal("build 13 retry failed", err)
				}
			} else if _, err := db.RefreshFirstPartySession(ctx, pair.RefreshToken); !errors.Is(err, ErrSessionAlreadyRotated) {
				t.Fatal("lost cookie response revoked session", err)
			}
			latest, err := db.RefreshFirstPartySession(ctx, rotated.RefreshToken)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := db.RefreshFirstPartySessionWithSuccessor(ctx, pair.RefreshToken, next); !errors.Is(err, ErrSessionInvalid) {
				t.Fatal("advanced-chain reuse did not revoke", err)
			}
			if _, _, err := db.GetUserByFirstPartyAccessToken(ctx, latest.AccessToken); !errors.Is(err, ErrSessionInvalid) {
				t.Fatal("latest access survived reuse", err)
			}
			if _, err := db.RefreshFirstPartySession(ctx, latest.RefreshToken); !errors.Is(err, ErrSessionInvalid) {
				t.Fatal("latest refresh survived reuse", err)
			}
		})
	}
}

func TestRecoveryKeyRevocationSharesProofTransaction(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := createPasswordTestUser(t, db)
	var email, keyID string
	if err := db.Get(&email, `SELECT email FROM users WHERE id=$1`, userID); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRow(`INSERT INTO api_keys(user_id,key_hash,key_prefix,name) VALUES($1,$2,'recovery-tx','Synthetic transaction key') RETURNING id`, userID, uuid.NewString()).Scan(&keyID); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO api_key_scopes(api_key_id,scope) VALUES($1,'capture:upload')`, keyID); err != nil {
		t.Fatal(err)
	}
	pair, err := db.CreateFirstPartySession(ctx, userID, "ios", "Recovery transaction")
	if err != nil {
		t.Fatal(err)
	}
	service, _ := emailservice.New("log", "", "", "synthetic-recovery-transaction")
	id := uuid.NewString()
	sealed, _ := service.Seal(emailservice.CodeMessage(email, "456789", "reset"))
	if _, err = db.IssueEmailChallenge(ctx, EmailChallenge{ID: id, Email: email, Purpose: "reset", CodeHash: service.CodeHash(id, "456789")}, sealed); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.Exec(`DELETE FROM auth_email_limits WHERE email=$1`, email) })
	err = db.CompleteEmailChallenge(ctx, "reset", email, "456789", "synthetic-encoded-replacement-password", service.CodeHash, func(string, string) (string, error) { return "", errors.New("synthetic notice failure") })
	if err == nil {
		t.Fatal("expected failed notice transaction")
	}
	var active bool
	if err = db.Get(&active, `SELECT active FROM api_keys WHERE id=$1`, keyID); err != nil || !active {
		t.Fatal("failed proof transaction revoked capture key", err)
	}
	if _, _, err = db.GetUserByFirstPartyAccessToken(ctx, pair.AccessToken); err != nil {
		t.Fatal("failed transaction revoked session")
	}
	if err = db.CompleteEmailChallenge(ctx, "reset", email, "456789", "synthetic-encoded-replacement-password", service.CodeHash, func(to, action string) (string, error) { return service.Seal(emailservice.Notice(to, action)) }); err != nil {
		t.Fatal(err)
	}
	if err = db.Get(&active, `SELECT active FROM api_keys WHERE id=$1`, keyID); err != nil || active {
		t.Fatal("successful proof retained capture key", err)
	}
}

func TestAutomaticUsageInitializesMissingPolicyAndExactOwner(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	for _, owner := range []bool{false, true} {
		userID := createPasswordTestUser(t, db)
		defaults := UsageDefaults{MonthlyMinutes: 2, MonthlyAIRequests: 1}
		if owner {
			defaults.OwnerUserID = userID
		}
		if err := db.ReserveAutomaticAIRequest(ctx, &userID, nil, "job:summary", defaults); err != nil {
			t.Fatal(err)
		}
		usage, err := db.AccountUsage(ctx, userID)
		if err != nil || usage.Exempt != owner || usage.AIRequestLimit != 1 {
			t.Fatal("missing automatic usage policy not initialized", err)
		}
		err = db.ReserveAutomaticAIRequest(ctx, &userID, nil, "job:title", defaults)
		if owner && err != nil || !owner && !IsUsageCap(err) {
			t.Fatal("automatic policy/exact owner bypass mismatch", err)
		}
	}
}
