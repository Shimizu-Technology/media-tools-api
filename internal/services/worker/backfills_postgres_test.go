package worker

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/storage"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/Shimizu-Technology/media-tools-api/internal/database"
	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	"github.com/Shimizu-Technology/media-tools-api/internal/services/summary"
	"github.com/google/uuid"
)

func backfillDB(t *testing.T) *database.DB {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL required")
	}
	db, err := database.NewWithSimpleProtocol(url, true)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	if err := db.RunMigrations("../../../migrations"); err != nil {
		t.Fatal(err)
	}
	return db
}

func TestBackfillDryRunDispatchAndLegacyCitedSummary(t *testing.T) {
	db := backfillDB(t)
	ctx := context.Background()
	user, id := uuid.NewString(), uuid.NewString()
	if _, err := db.Exec(`INSERT INTO users(id,email,password_hash) VALUES($1,$2,'unused')`, user, user+"@example.invalid"); err != nil {
		t.Fatal(err)
	}
	defer db.Exec(`DELETE FROM users WHERE id=$1`, user)
	// No timed segments: this verifies the actual legacy cited-summary path.
	if _, err := db.Exec(`INSERT INTO audio_transcriptions(id,filename,original_name,user_id,status,transcript_text,content_type) VALUES($1,'legacy.m4a','New Recording 5.m4a',$2,'completed','Please call tomorrow morning.','voice_memo')`, id, user); err != nil {
		t.Fatal(err)
	}
	defer db.Exec(`DELETE FROM audio_transcriptions WHERE id=$1`, id)
	defer db.Exec(`DELETE FROM background_jobs WHERE resource_id=$1`, id)
	pool := NewPool(3, 10, db, nil, summary.New("synthetic-test-key", "test/model"))
	defer pool.cancel()
	var before string
	if err := db.Get(&before, `SELECT row_to_json(a)::text FROM audio_transcriptions a WHERE id=$1`, id); err != nil {
		t.Fatal(err)
	}
	result, err := pool.RunBackfill(ctx, "enrichment", user, true)
	if err != nil || result.Eligible != 1 || result.Summaries != 1 || result.Titles != 1 || result.Enqueued != 0 || len(result.TitleNames) != 1 || result.TitleNames[0] != "New Recording 5.m4a" {
		t.Fatalf("dry run=%+v %v", result, err)
	}
	var after string
	db.Get(&after, `SELECT row_to_json(a)::text FROM audio_transcriptions a WHERE id=$1`, id)
	if before != after {
		t.Fatal("dry run modified audio")
	}
	var n int
	db.Get(&n, `SELECT count(*) FROM background_jobs WHERE resource_id=$1`, id)
	if n != 0 {
		t.Fatal("dry run queued a job")
	}
	run, err := db.CreateBackfillRun(ctx, "enrichment", user)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Exec(`DELETE FROM backfill_runs WHERE id=$1`, run)
	defer db.Exec(`DELETE FROM background_jobs WHERE resource_id=$1`, run)
	if err := pool.processBackfill(Job{ID: run}); err != nil {
		t.Fatal(err)
	}
	rows, _, err := db.ListLibraryItems(ctx, models.LibraryListParams{UserID: &user})
	if err != nil || len(rows) != 1 || rows[0].Status != "completed" {
		t.Fatalf("queued backfill changed library status %+v %v", rows, err)
	}

	progress, err := db.GetBackfillProgress(ctx, run)
	if err != nil || progress.Queued != 1 || progress.DispatchStatus != "completed" {
		t.Fatalf("progress %+v %v", progress, err)
	}
	// A restarted dispatcher cannot duplicate children, and an overlapping run
	// cannot adopt jobs that the first run created.
	if err := pool.processBackfill(Job{ID: run}); err != nil {
		t.Fatal(err)
	}
	otherRun, err := db.CreateBackfillRun(ctx, "enrichment", user)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Exec(`DELETE FROM backfill_runs WHERE id=$1`, otherRun)
	defer db.Exec(`DELETE FROM background_jobs WHERE resource_id=$1`, otherRun)
	if err := pool.processBackfill(Job{ID: otherRun}); err != nil {
		t.Fatal(err)
	}
	otherProgress, err := db.GetBackfillProgress(ctx, otherRun)
	if err != nil || otherProgress.Queued != 0 || otherProgress.Completed != 0 {
		t.Fatalf("overlapping run adopted work: %+v %v", otherProgress, err)
	}

	var job models.BackgroundJob
	if err := db.Get(&job, `SELECT * FROM background_jobs WHERE resource_id=$1 AND job_type='audio_summary'`, id); err != nil {
		t.Fatal(err)
	}
	original := http.DefaultTransport
	calls := 0
	http.DefaultTransport = emailTestTransport(func(r *http.Request) (*http.Response, error) {
		calls++
		body, _ := io.ReadAll(r.Body)
		content := "Tomorrow Morning Call"
		if !strings.Contains(string(body), "Give this recording") {
			// DB-generated untimed evidence IDs must reach the real summary service.
			ids := regexp.MustCompile(`id=\\"([0-9a-f-]{36})\\"`).FindSubmatch(body)
			if len(ids) != 2 {
				return nil, fmt.Errorf("legacy evidence ID missing from summary request")
			}
			content = fmt.Sprintf(`{"summary":{"text":"Call tomorrow morning.","citations":[%q]},"key_points":[],"action_items":[],"decisions":[],"topics":[]}`, string(ids[1]))
		}
		encoded, _ := json.Marshal(content)
		response := fmt.Sprintf(`{"model":"test/model","choices":[{"message":{"content":%s},"finish_reason":"stop"}]}`, encoded)
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(response))}, nil
	})
	defer func() { http.DefaultTransport = original }()
	if err := pool.processAudioSummary(Job{ID: id, QueueID: job.ID, Payload: job.Payload}); err != nil {
		t.Fatal(err)
	}
	item, err := db.GetAudioTranscription(ctx, id)
	if err != nil || item.SummaryStatus != "completed" || item.OriginalName != "Tomorrow Morning Call" || calls != 2 || item.ContentType != models.ContentVoiceMemo {
		t.Fatalf("item=%+v calls=%d err=%v", item, calls, err)
	}
	var evidence models.SummaryEvidence
	if err := json.Unmarshal(item.SummaryEvidence, &evidence); err != nil {
		t.Fatal(err)
	}
	if len(evidence.Summary) != 1 || evidence.Summary[0].StartMS != nil || evidence.Summary[0].SegmentID == "" {
		t.Fatalf("untimed citations=%+v", evidence)
	}
	// New jobs are deliberately absent from this run's counts.
	fresh := uuid.NewString()
	if _, err := db.Exec(`INSERT INTO background_jobs(job_type,resource_id) VALUES('audio_transcription',$1)`, fresh); err != nil {
		t.Fatal(err)
	}
	defer db.Exec(`DELETE FROM background_jobs WHERE resource_id=$1`, fresh)
	again, _ := db.GetBackfillProgress(ctx, run)
	if again.Queued != 1 {
		t.Fatalf("new job distorted counts: %+v", again)
	}
}

func TestWaveformFailureRetriesStayIndependent(t *testing.T) {
	db := backfillDB(t)
	id := uuid.NewString()
	if _, err := db.Exec(`INSERT INTO audio_transcriptions(id,filename,original_name,status,transcript_text,summary_status,waveform_status,audio_s3_key,audio_s3_status) VALUES($1,'bad','bad','completed','Existing speech','completed','pending','bad-source','uploaded')`, id); err != nil {
		t.Fatal(err)
	}
	defer db.Exec(`DELETE FROM audio_transcriptions WHERE id=$1`, id)
	defer db.Exec(`DELETE FROM background_jobs WHERE resource_id=$1`, id)
	if _, err := db.Exec(`INSERT INTO background_jobs(job_type,resource_id,max_attempts) VALUES('audio_waveform',$1,3)`, id); err != nil {
		t.Fatal(err)
	}
	original := http.DefaultTransport
	http.DefaultTransport = emailTestTransport(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader("corrupt MOV fixture"))}, nil
	})
	defer func() { http.DefaultTransport = original }()

	pool := NewPool(1, 1, db, nil, nil)
	pool.SetAudioStorage(storage.NewS3("synthetic-access", "synthetic-secret", "", "test-region", "test-bucket", "", 1))
	defer pool.cancel()
	for i := 1; i <= 3; i++ {
		var job models.BackgroundJob
		if err := db.Get(&job, `UPDATE background_jobs SET status='running',attempts=attempts+1,locked_by=$2,lease_expires_at=NOW()+INTERVAL '1 minute' WHERE resource_id=$1 RETURNING *`, id, pool.instanceID); err != nil {
			t.Fatal(err)
		}
		pool.runClaimedJob(0, &job)
		var state string
		if err := db.Get(&state, `SELECT status FROM background_jobs WHERE resource_id=$1`, id); err != nil {
			t.Fatal(err)
		}
		want := "queued"
		if i == 3 {
			want = "failed"
		}
		if state != want {
			t.Fatalf("attempt %d status %s want %s", i, state, want)
		}
	}
	at, err := db.GetAudioTranscription(context.Background(), id)
	if err != nil || at.Status != "completed" || at.SummaryStatus != "completed" || at.WaveformStatus != "failed" || len(at.Waveform) != 0 {
		t.Fatalf("independent failure %+v %v", at, err)
	}
}

func TestStoredAudioWaveformDurableJob(t *testing.T) {
	t.Setenv("AUTOMATIC_AUDIO_ENRICHMENT_ENABLED", "false")
	db := backfillDB(t)
	id := uuid.NewString()
	if _, err := db.Exec(`INSERT INTO audio_transcriptions(id,filename,original_name,status,transcript_text,summary_status,waveform_status,audio_s3_key,audio_s3_status) VALUES($1,'source.qta','Chosen title','pending','Existing speech','completed','pending','test/source','uploaded')`, id); err != nil {
		t.Fatal(err)
	}
	defer db.Exec(`DELETE FROM audio_transcriptions WHERE id=$1`, id)
	defer db.Exec(`DELETE FROM background_jobs WHERE resource_id=$1`, id)
	if _, err := db.Exec(`INSERT INTO background_jobs(job_type,resource_id,max_attempts) VALUES('audio_waveform',$1,3)`, id); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "source.qta")
	if out, err := exec.Command("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-c:a", "aac", "-f", "mov", path).CombinedOutput(); err != nil {
		t.Fatalf("fixture %v %s", err, out)
	}
	original := http.DefaultTransport
	http.DefaultTransport = emailTestTransport(func(r *http.Request) (*http.Response, error) {
		if r.Method != "GET" || !strings.Contains(r.URL.Host, "s3") {
			return nil, fmt.Errorf("unexpected waveform network request")
		}
		active, err := db.GetAudioTranscription(context.Background(), id)
		if err != nil {
			return nil, err
		}
		active.Status = "completed"
		if saved, err := db.CompleteAudioTranscriptionWithSegments(context.Background(), active, nil); err != nil || !saved {
			return nil, fmt.Errorf("retranscription completion saved=%v: %w", saved, err)
		}
		file, err := os.Open(path)
		if err != nil {
			return nil, err
		}
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: file}, nil
	})
	defer func() { http.DefaultTransport = original }()
	pool := NewPool(3, 10, db, nil, nil)
	defer pool.cancel()
	pool.SetAudioStorage(storage.NewS3("synthetic-access", "synthetic-secret", "", "test-region", "test-bucket", "", 1))
	var job models.BackgroundJob
	if err := db.Get(&job, `UPDATE background_jobs SET status='running',attempts=1,locked_by=$2,lease_expires_at=NOW()+INTERVAL '1 minute' WHERE resource_id=$1 AND job_type='audio_waveform' RETURNING *`, id, pool.instanceID); err != nil {
		t.Fatal(err)
	}
	pool.runClaimedJob(0, &job)
	at, err := db.GetAudioTranscription(context.Background(), id)
	if err != nil {
		t.Fatal(err)
	}
	var peaks []int
	if err := json.Unmarshal(at.Waveform, &peaks); err != nil {
		t.Fatal(err)
	}
	if len(peaks) != 200 || at.WaveformStatus != "completed" || at.Status != "completed" || at.SummaryStatus != "completed" || at.OriginalName != "Chosen title" {
		t.Fatalf("waveform result %+v", at)
	}
}

func TestBackfillProtectsChosenTitlesAndSummaryOptOut(t *testing.T) {
	db := backfillDB(t)
	user := uuid.NewString()
	if _, err := db.Exec(`INSERT INTO users(id,email,password_hash) VALUES($1,$2,'unused')`, user, user+"@example.invalid"); err != nil {
		t.Fatal(err)
	}
	defer db.Exec(`DELETE FROM users WHERE id=$1`, user)
	if _, err := db.Exec(`INSERT INTO processing_preferences(user_id,automatic_summaries) VALUES($1,false)`, user); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name   string
		manual bool
	}{{"Meeting with Dana", false}, {"New Recording 5.m4a", true}, {"New Recording 6.m4a", false}} {
		id := uuid.NewString()
		if _, err := db.Exec(`INSERT INTO audio_transcriptions(id,filename,original_name,status,user_id,transcript_text,title_manually_set) VALUES($1,'source.m4a',$2,'completed',$3,'Some source speech',$4)`, id, tc.name, user, tc.manual); err != nil {
			t.Fatal(err)
		}
		defer db.Exec(`DELETE FROM audio_transcriptions WHERE id=$1`, id)
		defer db.Exec(`DELETE FROM background_jobs WHERE resource_id=$1`, id)
	}
	pool := NewPool(3, 10, db, nil, nil)
	defer pool.cancel()
	result, err := pool.RunBackfill(context.Background(), "enrichment", user, true)
	if err != nil || result.Eligible != 1 || result.Summaries != 0 || result.Titles != 1 || result.ProtectedTitles != 1 {
		t.Fatalf("preferences/protection %+v %v", result, err)
	}
	result, err = pool.RunBackfill(context.Background(), "enrichment", user, false)
	if err != nil || result.Enqueued != 1 {
		t.Fatalf("queue opted out %+v %v", result, err)
	}
	var payload string
	if err := db.Get(&payload, `SELECT payload::text FROM background_jobs j JOIN audio_transcriptions a ON a.id=j.resource_id WHERE a.user_id=$1`, user); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(payload, `"title_only": true`) {
		t.Fatal("summary opt-out did not produce a title-only job")
	}
}

// Migration 055 flagged every recording that existed on 2026-11-04, so the flag on
// an old row does not mean a person chose its name.
func TestEnrichmentBackfillRetitlesOnlyOldExactPlaceholders(t *testing.T) {
	db := backfillDB(t)
	user := uuid.NewString()
	if _, err := db.Exec(`INSERT INTO users(id,email,password_hash) VALUES($1,$2,'unused')`, user, user+"@example.invalid"); err != nil {
		t.Fatal(err)
	}
	defer db.Exec(`DELETE FROM users WHERE id=$1`, user)
	if _, err := db.Exec(`INSERT INTO processing_preferences(user_id,automatic_summaries) VALUES($1,false)`, user); err != nil {
		t.Fatal(err)
	}
	old, recent := "2026-02-03T10:00:00Z", "2026-11-06T10:00:00Z"
	ids := map[string]string{}
	for _, tc := range []struct{ name, created string }{
		{"recording-2026-02-03-14-22-01.webm", old},
		{"Recording of the 2024 budget meeting.m4a", old},
		{"New Recording Mr. Mon Mendiola for UOG.m4a", old},
		{"New Recording 7.m4a", recent},
		{"Recording — Aug 26, 2026 at 10:35 AM.m4a", old},
		{"New Recording 12. Mon Mendiola", old},
		{"Recording. Dad's story about Guam", old},
		{"Untitled. Call with the bank", old},
		{"Voice Memo 3.Hafa Baby", old},
		{"New Recording 7.Baby's first words", old},
		{"Recording — Mayor interview 2026 at 10:35 AM", old},
	} {
		id := uuid.NewString()
		ids[tc.name] = id
		if _, err := db.Exec(`INSERT INTO audio_transcriptions(id,filename,original_name,status,user_id,transcript_text,title_manually_set,created_at) VALUES($1,'source.m4a',$2,'completed',$3,'Some source speech',true,$4)`, id, tc.name, user, tc.created); err != nil {
			t.Fatal(err)
		}
		defer db.Exec(`DELETE FROM audio_transcriptions WHERE id=$1`, id)
		defer db.Exec(`DELETE FROM background_jobs WHERE resource_id=$1`, id)
	}
	pool := NewPool(3, 10, db, nil, nil)
	defer pool.cancel()
	dry, err := pool.RunBackfill(context.Background(), "enrichment", user, true)
	if err != nil || dry.Titles != 2 || len(dry.TitleNames) != 2 || dry.Enqueued != 0 {
		t.Fatalf("dry run %+v %v", dry, err)
	}
	var flagged bool
	if err := db.Get(&flagged, `SELECT title_manually_set FROM audio_transcriptions WHERE id=$1`, ids["recording-2026-02-03-14-22-01.webm"]); err != nil || !flagged {
		t.Fatalf("dry run changed the flag: %v %v", flagged, err)
	}
	result, err := pool.RunBackfill(context.Background(), "enrichment", user, false)
	if err != nil || result.Enqueued != 2 {
		t.Fatalf("real run %+v %v", result, err)
	}
	for name, id := range ids {
		var manual bool
		var jobs int
		if err := db.Get(&manual, `SELECT title_manually_set FROM audio_transcriptions WHERE id=$1`, id); err != nil {
			t.Fatal(err)
		}
		if err := db.Get(&jobs, `SELECT count(*) FROM background_jobs WHERE resource_id=$1`, id); err != nil {
			t.Fatal(err)
		}
		placeholder := name == "recording-2026-02-03-14-22-01.webm" || name == "Recording — Aug 26, 2026 at 10:35 AM.m4a"
		if manual == placeholder || (jobs == 1) != placeholder {
			t.Errorf("%q: manual=%v jobs=%d", name, manual, jobs)
		}
	}
}
