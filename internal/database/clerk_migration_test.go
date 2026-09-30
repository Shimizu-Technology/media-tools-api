package database

import (
	"context"
	"errors"
	"sync"
	"testing"

	"github.com/google/uuid"
)

func TestResolveMigrationClerkUserOnlyAcceptsExistingLinks(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()

	linkedSubject := "user_" + uuid.NewString()
	legacySubject := "user_" + uuid.NewString()
	unknownSubject := "user_" + uuid.NewString()
	sameEmail := uuid.NewString() + "@example.com"

	var linkedID, legacyID, sameEmailID string
	if err := db.QueryRowContext(ctx, `INSERT INTO users (email, password_hash, name) VALUES ($1, '', 'Linked') RETURNING id`, uuid.NewString()+"@example.com").Scan(&linkedID); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRowContext(ctx, `INSERT INTO users (email, password_hash, name, clerk_id) VALUES ($1, '', 'Legacy', $2) RETURNING id`, uuid.NewString()+"@example.com", legacySubject).Scan(&legacyID); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRowContext(ctx, `INSERT INTO users (email, password_hash, name) VALUES ($1, '', 'Same Email') RETURNING id`, sameEmail).Scan(&sameEmailID); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = db.ExecContext(context.Background(), `DELETE FROM users WHERE id IN ($1, $2, $3)`, linkedID, legacyID, sameEmailID)
	})
	if err := db.EnsureAuthIdentity(ctx, linkedID, "clerk", linkedSubject); err != nil {
		t.Fatal(err)
	}

	linked, err := db.ResolveMigrationClerkUser(ctx, linkedSubject)
	if err != nil || linked.ID != linkedID || linked.ClerkID == nil || *linked.ClerkID != linkedSubject {
		t.Fatalf("linked identity = %#v, %v", linked, err)
	}

	legacy, err := db.ResolveMigrationClerkUser(ctx, legacySubject)
	if err != nil || legacy.ID != legacyID {
		t.Fatalf("legacy identity = %#v, %v", legacy, err)
	}
	var legacyLinks int
	if err := db.GetContext(ctx, &legacyLinks, `SELECT COUNT(*) FROM auth_identities WHERE provider = 'clerk' AND subject = $1 AND user_id = $2`, legacySubject, legacyID); err != nil || legacyLinks != 1 {
		t.Fatalf("legacy identity backfill count = %d, %v", legacyLinks, err)
	}

	var usersBefore, identitiesBefore int
	if err := db.GetContext(ctx, &usersBefore, `SELECT COUNT(*) FROM users`); err != nil {
		t.Fatal(err)
	}
	if err := db.GetContext(ctx, &identitiesBefore, `SELECT COUNT(*) FROM auth_identities`); err != nil {
		t.Fatal(err)
	}

	// The unknown Clerk account may have the same verified email at the
	// provider. Email never enters this resolver, so it cannot claim the row.
	const concurrentRequests = 12
	errs := make(chan error, concurrentRequests)
	var wg sync.WaitGroup
	for i := 0; i < concurrentRequests; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := db.ResolveMigrationClerkUser(ctx, unknownSubject)
			errs <- err
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if !errors.Is(err, ErrClerkIdentityUnknown) {
			t.Fatalf("unknown identity error = %v", err)
		}
	}

	var usersAfter, identitiesAfter int
	if err := db.GetContext(ctx, &usersAfter, `SELECT COUNT(*) FROM users`); err != nil {
		t.Fatal(err)
	}
	if err := db.GetContext(ctx, &identitiesAfter, `SELECT COUNT(*) FROM auth_identities`); err != nil {
		t.Fatal(err)
	}
	if usersAfter != usersBefore || identitiesAfter != identitiesBefore {
		t.Fatalf("unknown identity wrote rows: users %d -> %d, identities %d -> %d", usersBefore, usersAfter, identitiesBefore, identitiesAfter)
	}
	var ownerClerkID *string
	if err := db.GetContext(ctx, &ownerClerkID, `SELECT clerk_id FROM users WHERE id = $1`, sameEmailID); err != nil || ownerClerkID != nil {
		t.Fatalf("same-email account was linked: clerk_id=%v err=%v", ownerClerkID, err)
	}
}
