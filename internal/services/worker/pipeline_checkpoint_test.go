package worker

import (
	"context"
	"fmt"
	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/audio"
	"github.com/google/uuid"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type checkpointTransport func(*http.Request) (*http.Response, error)

func (f checkpointTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func TestCompletedChunkResumesWithoutProviderCall(t *testing.T) {
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL required")
	}
	db, err := database.NewWithSimpleProtocol(url, true)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	id := uuid.NewString()
	ctx := context.Background()
	if _, err := db.ExecContext(ctx, `INSERT INTO audio_transcriptions(id,filename,original_name,status) VALUES($1,'chunk.mp3','chunk.mp3','processing')`, id); err != nil {
		t.Fatal(err)
	}
	defer db.ExecContext(ctx, `DELETE FROM audio_transcriptions WHERE id=$1`, id)
	calls := 0
	original := http.DefaultTransport
	http.DefaultTransport = checkpointTransport(func(r *http.Request) (*http.Response, error) {
		calls++
		io.Copy(io.Discard, r.Body)
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(`{"text":"Please call tomorrow morning.","duration":60,"language":"en"}`))}, nil
	})
	defer func() { http.DefaultTransport = original }()
	path := filepath.Join(t.TempDir(), "chunk.mp3")
	if err := os.WriteFile(path, []byte("fake provider fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	for attempt := 0; attempt < 2; attempt++ {
		p := NewPool(1, 1, db, nil, nil)
		p.SetAudioTranscriber(audio.NewTranscriber("fake-key"))
		results, err := p.transcribeChunks(ctx, id, "private.mp3", []string{path}, 60, 60)
		if err != nil {
			t.Fatal(err)
		}
		if len(results) != 1 || results[0].Text == "" {
			t.Fatal(fmt.Sprint(results))
		}
	}
	if calls != 1 {
		t.Fatalf("provider calls=%d, want 1 across restart", calls)
	}
}

func TestPanickingJobAtomicallyFailsItsItem(t *testing.T) {
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL required")
	}
	db, err := database.NewWithSimpleProtocol(url, true)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ctx := context.Background()
	id := uuid.NewString()
	if _, err := db.ExecContext(ctx, `INSERT INTO transcripts(id,youtube_url,youtube_id,status) VALUES($1,'https://example.test/video','panic-fixture','pending')`, id); err != nil {
		t.Fatal(err)
	}
	defer db.ExecContext(ctx, `DELETE FROM transcripts WHERE id=$1`, id)
	defer db.ExecContext(ctx, `DELETE FROM background_jobs WHERE resource_id=$1`, id)
	p := NewPool(1, 1, db, nil, nil)
	var job models.BackgroundJob
	if err := db.GetContext(ctx, &job, `UPDATE background_jobs SET status='running',locked_by=$2,lease_expires_at=NOW()+INTERVAL '1 minute',attempts=1 WHERE resource_id=$1 RETURNING *`, id, p.instanceID); err != nil {
		t.Fatal(err)
	}
	p.runClaimedJob(0, &job)
	p.Stop()
	var itemStatus, jobStatus string
	if err := db.QueryRowContext(ctx, `SELECT t.status,j.status FROM transcripts t JOIN background_jobs j ON j.resource_id=t.id WHERE t.id=$1`, id).Scan(&itemStatus, &jobStatus); err != nil {
		t.Fatal(err)
	}
	if itemStatus != "failed" || jobStatus != "failed" {
		t.Fatalf("item=%s job=%s", itemStatus, jobStatus)
	}
}
