package database

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
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
	results := make(chan error, 2)
	var workers sync.WaitGroup
	for i := 0; i < 2; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			_, err := db.RedeemRecoveryCode(ctx, codes[0], "ios", "Replacement phone")
			results <- err
		}()
	}
	workers.Wait()
	close(results)
	var successes, rejections int
	for err := range results {
		if err == nil {
			successes++
		} else if errors.Is(err, ErrRecoveryCodeInvalid) {
			rejections++
		} else {
			t.Fatal(err)
		}
	}
	if successes != 1 || rejections != 1 {
		t.Fatalf("concurrent redemptions: success=%d rejected=%d", successes, rejections)
	}
}
