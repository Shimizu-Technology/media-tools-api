package database

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestFirstPartyTokenFormat(t *testing.T) {
	first, err := randomAuthToken("mta_at_")
	if err != nil {
		t.Fatal(err)
	}
	second, err := randomAuthToken("mta_at_")
	if err != nil {
		t.Fatal(err)
	}
	if first == second {
		t.Fatal("random credentials repeated")
	}
	if _, ok := authTokenHash(first, "mta_at_"); !ok {
		t.Fatal("generated credential could not be hashed")
	}
	for _, malformed := range []string{"", "mta_at_", "mta_rt_" + first[7:], first + "=", first + "x"} {
		if _, ok := authTokenHash(malformed, "mta_at_"); ok {
			t.Fatalf("accepted malformed access credential %q", malformed)
		}
	}
}

func TestFirstPartySessionRotationReplayAndRevocation(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	var userID string
	if err := db.QueryRowContext(ctx, `
		INSERT INTO users (email, password_hash, name)
		VALUES ($1, '', 'Session Test') RETURNING id`, uuid.NewString()+"@example.com").Scan(&userID); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, userID) })

	pair, err := db.CreateFirstPartySession(ctx, userID, "ios", "Test iPhone")
	if err != nil {
		t.Fatalf("create session: %v", err)
	}
	if pair.UserID != userID || pair.SessionID == "" {
		t.Fatalf("session ownership = %#v", pair)
	}
	user, sessionID, err := db.GetUserByFirstPartyAccessToken(ctx, pair.AccessToken)
	if err != nil || user.ID != userID || sessionID != pair.SessionID {
		t.Fatalf("access credential owner = %#v, %q, %v", user, sessionID, err)
	}
	if _, _, err := db.GetUserByFirstPartyAccessToken(ctx, pair.RefreshToken); !errors.Is(err, ErrSessionInvalid) {
		t.Fatalf("refresh credential accepted as access credential: %v", err)
	}

	rotated, err := db.RefreshFirstPartySession(ctx, pair.RefreshToken)
	if err != nil || rotated.SessionID != pair.SessionID || rotated.RefreshToken == pair.RefreshToken {
		t.Fatalf("rotate session = %#v, %v", rotated, err)
	}
	if _, err := db.RefreshFirstPartySession(ctx, pair.RefreshToken); !errors.Is(err, ErrSessionAlreadyRotated) {
		t.Fatalf("recent duplicate refresh = %v", err)
	}
	if _, _, err := db.GetUserByFirstPartyAccessToken(ctx, rotated.AccessToken); err != nil {
		t.Fatalf("rotated access credential failed: %v", err)
	}

	oldHash, _ := authTokenHash(pair.RefreshToken, "mta_rt_")
	if _, err := db.ExecContext(ctx, `UPDATE auth_refresh_tokens SET consumed_at = $2 WHERE token_hash = $1`, oldHash, time.Now().Add(-duplicateRefreshGrace-time.Second)); err != nil {
		t.Fatal(err)
	}
	if _, err := db.RefreshFirstPartySession(ctx, pair.RefreshToken); !errors.Is(err, ErrSessionReplay) {
		t.Fatalf("old credential replay = %v", err)
	}
	if _, _, err := db.GetUserByFirstPartyAccessToken(ctx, rotated.AccessToken); !errors.Is(err, ErrSessionInvalid) {
		t.Fatalf("replayed session still has access: %v", err)
	}
	if _, err := db.RefreshFirstPartySession(ctx, rotated.RefreshToken); !errors.Is(err, ErrSessionInvalid) {
		t.Fatalf("replayed session still refreshes: %v", err)
	}
}

func TestFirstPartyRefreshRecoversLostResponse(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	var userID string
	if err := db.QueryRowContext(ctx, `INSERT INTO users (email, password_hash) VALUES ($1, '') RETURNING id`, uuid.NewString()+"@example.com").Scan(&userID); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, userID) })
	initial, err := db.CreateFirstPartySession(ctx, userID, "ios", "Phone")
	if err != nil {
		t.Fatal(err)
	}
	next, err := randomAuthToken("mta_rt_")
	if err != nil {
		t.Fatal(err)
	}
	first, err := db.RefreshFirstPartySessionWithSuccessor(ctx, initial.RefreshToken, next)
	if err != nil || first.RefreshToken != next {
		t.Fatalf("initial rotation = %#v, %v", first, err)
	}
	oldHash, _ := authTokenHash(initial.RefreshToken, "mta_rt_")
	if _, err := db.ExecContext(ctx, `UPDATE auth_refresh_tokens SET consumed_at = $2 WHERE token_hash = $1`, oldHash, time.Now().Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	recovered, err := db.RefreshFirstPartySessionWithSuccessor(ctx, initial.RefreshToken, next)
	if err != nil || recovered.RefreshToken != next || recovered.AccessToken == first.AccessToken || recovered.SessionID != first.SessionID {
		t.Fatalf("recover interrupted response = %#v, %v", recovered, err)
	}
	if _, _, err := db.GetUserByFirstPartyAccessToken(ctx, recovered.AccessToken); err != nil {
		t.Fatalf("recovered access credential failed: %v", err)
	}
	third, err := randomAuthToken("mta_rt_")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.RefreshFirstPartySessionWithSuccessor(ctx, next, third); err != nil {
		t.Fatalf("advance to third credential: %v", err)
	}
	if _, err := db.RefreshFirstPartySessionWithSuccessor(ctx, initial.RefreshToken, next); !errors.Is(err, ErrSessionAlreadyRotated) {
		t.Fatalf("stale recovery after successor was spent = %v", err)
	}
	if _, _, err := db.GetUserByFirstPartyAccessToken(ctx, recovered.AccessToken); err != nil {
		t.Fatalf("stale recovery revoked device: %v", err)
	}
}

func TestFirstPartySessionCannotBeRevokedByAnotherUser(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	var ownerID, otherID string
	for _, target := range []*string{&ownerID, &otherID} {
		if err := db.QueryRowContext(ctx, `INSERT INTO users (email, password_hash) VALUES ($1, '') RETURNING id`, uuid.NewString()+"@example.com").Scan(target); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, *target) })
	}
	pair, err := db.CreateFirstPartySession(ctx, ownerID, "web", "Browser")
	if err != nil {
		t.Fatal(err)
	}
	if revoked, err := db.RevokeFirstPartySession(ctx, otherID, pair.SessionID); err != nil || revoked {
		t.Fatalf("other user revoked session: %v, %v", revoked, err)
	}
	if revoked, err := db.RevokeFirstPartySession(ctx, ownerID, pair.SessionID); err != nil || !revoked {
		t.Fatalf("owner failed to revoke session: %v, %v", revoked, err)
	}
	if _, _, err := db.GetUserByFirstPartyAccessToken(ctx, pair.AccessToken); !errors.Is(err, ErrSessionInvalid) {
		t.Fatalf("revoked session still has access: %v", err)
	}
}

func TestVerifiedIdentityCannotMoveBetweenUsers(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	var firstID, secondID string
	for _, target := range []*string{&firstID, &secondID} {
		if err := db.QueryRowContext(ctx, `INSERT INTO users (email, password_hash) VALUES ($1, '') RETURNING id`, uuid.NewString()+"@example.com").Scan(target); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id = $1`, *target) })
	}
	subject := "user_" + uuid.NewString()
	if err := db.EnsureAuthIdentity(ctx, firstID, "clerk", subject); err != nil {
		t.Fatal(err)
	}
	if err := db.EnsureAuthIdentity(ctx, firstID, "clerk", subject); err != nil {
		t.Fatalf("idempotent identity link failed: %v", err)
	}
	if err := db.EnsureAuthIdentity(ctx, secondID, "clerk", subject); !errors.Is(err, ErrIdentityOwnedByOther) {
		t.Fatalf("cross-account identity link = %v", err)
	}
}
