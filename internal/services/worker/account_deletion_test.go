package worker

import (
	"context"
	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/google/uuid"
	"os"
	"testing"
	"time"
)

func TestPendingRetiredProviderDeletionCompletes(t *testing.T) {
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("local database required")
	}
	db, err := database.New(url)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := db.RunMigrations("../../../migrations"); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	var id string
	err = db.QueryRowContext(ctx, `INSERT INTO users(email,password_hash) VALUES($1,'') RETURNING id`, uuid.NewString()+"@example.invalid").Scan(&id)
	if err != nil {
		t.Fatal(err)
	}
	request, err := db.RequestAccountDeletion(ctx, id, nil, time.Now().Add(-time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	defer db.ExecContext(ctx, `DELETE FROM account_deletion_requests WHERE id=$1`, request.ID)
	// Recreate a request persisted by the previous worker before provider cleanup.
	_, err = db.ExecContext(ctx, `UPDATE account_deletion_requests SET clerk_deleted_at=NULL, cleanup_after=NOW()-INTERVAL '1 minute' WHERE id=$1`, request.ID)
	if err != nil {
		t.Fatal(err)
	}
	p := &Pool{db: db, ctx: ctx}
	if err := p.processAccountDeletion(Job{ID: request.ID}); err != nil {
		t.Fatal(err)
	}
	got, err := db.GetAccountDeletionRequest(ctx, request.ID)
	if err != nil || got.Status != "completed" || got.ProviderDeletedAt == nil {
		t.Fatal("pending provider step did not complete")
	}
}
