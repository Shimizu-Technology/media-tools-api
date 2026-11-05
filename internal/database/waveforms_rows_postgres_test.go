package database

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	"github.com/google/uuid"
)

func TestWaveformCompletionFailureAndPriority(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	// Freeze unrelated leftovers in this dedicated test DB, then restore them.
	var baseline []struct {
		ID    string
		RunAt time.Time    `db:"run_at"`
		Lease sql.NullTime `db:"lease_expires_at"`
	}
	if err := db.Select(&baseline, `SELECT id,run_at,lease_expires_at FROM background_jobs WHERE status IN ('queued','running')`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`UPDATE background_jobs SET run_at=NOW()+INTERVAL '1 day',lease_expires_at=NOW()+INTERVAL '1 day' WHERE status IN ('queued','running')`); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		for _, job := range baseline {
			db.Exec(`UPDATE background_jobs SET run_at=$2,lease_expires_at=$3 WHERE id=$1`, job.ID, job.RunAt, job.Lease)
		}
	})
	maintenance := insertTestAudio(t, db, "processing")
	if _, err := db.Exec(`UPDATE audio_transcriptions SET audio_s3_key='test/source',audio_s3_status='uploaded' WHERE id=$1`, maintenance); err != nil {
		t.Fatal(err)
	}
	at, err := db.GetAudioTranscription(ctx, maintenance)
	if err != nil {
		t.Fatal(err)
	}
	at.Status = "completed"
	at.TranscriptText = "Stored transcript"
	at.SummaryStatus = "completed"
	at.OmittedRanges = []byte(`[]`)
	if saved, err := db.CompleteAudioTranscriptionWithSegments(ctx, at, nil); err != nil || !saved {
		t.Fatalf("saved=%v err=%v", saved, err)
	}
	var priority, maxAttempts int
	if err := db.QueryRow(`SELECT priority,max_attempts FROM background_jobs WHERE job_type='audio_waveform' AND resource_id=$1`, maintenance).Scan(&priority, &maxAttempts); err != nil || priority != 5 || maxAttempts != 3 {
		t.Fatalf("priority=%d attempts=%d err=%v", priority, maxAttempts, err)
	}
	// Treat this queued work as a backfill after checking the normal producer.
	if _, err := db.Exec(`UPDATE background_jobs SET priority=10 WHERE resource_id=$1 AND job_type='audio_waveform'`, maintenance); err != nil {
		t.Fatal(err)
	}
	fresh := insertTestAudio(t, db, "pending")
	job, err := db.ClaimBackgroundJob(ctx, "new-recorder", time.Minute)
	if err != nil || job == nil || job.ResourceID != fresh {
		t.Fatalf("fresh recording must precede maintenance: %+v %v", job, err)
	}
	if err := db.CompleteBackgroundJob(ctx, job.ID, "new-recorder"); err != nil {
		t.Fatal(err)
	}
	job, err = db.ClaimBackgroundJob(ctx, "maintenance", time.Minute)
	if err != nil || job == nil || job.JobType != "audio_waveform" {
		t.Fatalf("waveform claim %+v %v", job, err)
	}
	second := insertTestAudio(t, db, "completed")
	if _, err := db.Exec(`INSERT INTO background_jobs(job_type,resource_id,priority) VALUES('audio_waveform',$1,10)`, second); err != nil {
		t.Fatal(err)
	}
	if next, err := db.ClaimBackgroundJob(ctx, "other", time.Minute); err != nil || next != nil {
		t.Fatalf("second maintenance occupied reserved capacity: %+v %v", next, err)
	}
	freshDuringBackfill := insertTestAudio(t, db, "pending")
	next, err := db.ClaimBackgroundJob(ctx, "during-backfill", time.Minute)
	if err != nil || next == nil || next.ResourceID != freshDuringBackfill {
		t.Fatalf("fresh work blocked by running backfill: %+v %v", next, err)
	}
	if err := db.CompleteBackgroundJob(ctx, next.ID, "during-backfill"); err != nil {
		t.Fatal(err)
	}
	if err := db.FailBackgroundJob(ctx, job.ID, "maintenance", "bad codec"); err != nil {
		t.Fatal(err)
	}
	got, err := db.GetAudioTranscription(ctx, maintenance)
	if err != nil || got.Status != "completed" || got.WaveformStatus != "failed" || got.TranscriptText != "Stored transcript" {
		t.Fatalf("failure changed transcription: %+v %v", got, err)
	}
}

func TestLibraryRowFieldsAndLeastUsedCollectionColors(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	user := insertAIReportUser(t, db)
	id := insertTestAudio(t, db, "completed")
	peaks := make([]int, 200)
	for i := range peaks {
		peaks[i] = i % 101
	}
	encoded, _ := json.Marshal(peaks)
	if _, err := db.Exec(`UPDATE audio_transcriptions SET user_id=$2,transcript_text='Fallback transcript',summary_text=$3,waveform=$4::jsonb,waveform_status='completed' WHERE id=$1`, id, user, `{"summary":{"text":"## **A clear summary** [1] with [a link](https://example.test)."}}`, string(encoded)); err != nil {
		t.Fatal(err)
	}
	colors := []string{"coral", "teal", "violet", "amber", "blue", "rose", "coral"}
	for i, color := range colors {
		c := models.Collection{Name: fmt.Sprintf("Collection %d", i), UserID: &user}
		if err := db.CreateCollection(ctx, &c); err != nil {
			t.Fatal(err)
		}
		if c.Color != color {
			t.Fatalf("color %d=%s want %s", i, c.Color, color)
		}
		t.Cleanup(func() { db.Exec(`DELETE FROM collections WHERE id=$1`, c.ID) })
		if _, err := db.AddCollectionItems(ctx, c.ID, []models.CollectionItemInput{{ItemType: "audio", ItemID: id}}); err != nil {
			t.Fatal(err)
		}
	}
	items, total, err := db.ListLibraryItems(ctx, models.LibraryListParams{UserID: &user})
	if err != nil || total != 1 || len(items) != 1 {
		t.Fatalf("rows=%d total=%d err=%v", len(items), total, err)
	}
	if items[0].Excerpt != "A clear summary with a link." {
		t.Fatal(items[0].Excerpt)
	}
	var rowPeaks []int
	json.Unmarshal(items[0].Waveform, &rowPeaks)
	var collections []models.Collection
	json.Unmarshal(items[0].Collections, &collections)
	if len(rowPeaks) != 32 || len(collections) != 7 || collections[0].Name != "Collection 0" {
		t.Fatalf("peaks=%d collections=%+v", len(rowPeaks), collections)
	}
	detail, err := db.GetAudioTranscriptionForActor(ctx, id, &user, nil)
	var detailPeaks []int
	if detail != nil {
		json.Unmarshal(detail.Waveform, &detailPeaks)
	}
	if err != nil || len(detailPeaks) != 200 {
		t.Fatalf("detail peaks=%d err=%v", len(detailPeaks), err)
	}
	if _, err := db.Exec(`UPDATE audio_transcriptions SET summary_text='',waveform=NULL WHERE id=$1`, id); err != nil {
		t.Fatal(err)
	}
	items, _, err = db.ListLibraryItems(ctx, models.LibraryListParams{UserID: &user})
	if err != nil || items[0].Excerpt != "Fallback transcript" || len(items[0].Waveform) != 0 {
		t.Fatalf("fallback %+v %v", items, err)
	}
}

func TestBackfillStrictOwnershipAndIdempotency(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	user := insertAIReportUser(t, db)
	other := insertAIReportUser(t, db)
	key := uuid.NewString()
	if _, err := db.Exec(`INSERT INTO api_keys(id,key_hash,key_prefix,name,user_id) VALUES($1,$2,'test','Legacy',$3)`, key, uuid.NewString(), user); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Exec(`DELETE FROM api_keys WHERE id=$1`, key) })
	id := insertTestAudio(t, db, "completed")
	failed := insertTestAudio(t, db, "failed")
	foreign := insertTestAudio(t, db, "completed")
	for _, audio := range []string{id, failed, foreign} {
		if _, err := db.Exec(`UPDATE audio_transcriptions SET api_key_id=$2,transcript_text='Legacy content' WHERE id=$1`, audio, key); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := db.Exec(`UPDATE audio_transcriptions SET user_id=$2 WHERE id=$1`, foreign, other); err != nil {
		t.Fatal(err)
	}
	// A key-only row is not account-owned. Classic key reads still see it.
	candidates, err := db.ListBackfillCandidates(ctx, "enrichment", user)
	if err != nil || len(candidates) != 0 {
		t.Fatalf("key-only backfill selected %+v %v", candidates, err)
	}
	if _, err := db.GetAudioTranscriptionForActor(ctx, id, &user, nil); err == nil {
		t.Fatal("account read key-only row")
	}
	classic, total, err := db.ListLibraryItems(ctx, models.LibraryListParams{APIKeyID: &key})
	if err != nil || total != 3 || len(classic) != 3 {
		t.Fatalf("classic key reads changed: %d %v", total, err)
	}
	if _, err := db.Exec(`UPDATE audio_transcriptions SET user_id=$2 WHERE id=$1`, id, user); err != nil {
		t.Fatal(err)
	}
	candidates, err = db.ListBackfillCandidates(ctx, "enrichment", user)
	if err != nil || len(candidates) != 1 || candidates[0].ID != id {
		t.Fatalf("owned candidates=%+v %v", candidates, err)
	}
	rows, total, err := db.ListLibraryItems(ctx, models.LibraryListParams{UserID: &user})
	if err != nil || total != 1 || len(rows) != 1 {
		t.Fatalf("library ownership=%+v %d %v", rows, total, err)
	}
	for attempt := 0; attempt < 2; attempt++ {
		queued, err := db.QueueBackfillCandidate(ctx, "enrichment", user, candidates[0], "", true)
		if err != nil || queued != (attempt == 0) {
			t.Fatalf("attempt=%d queued=%v err=%v", attempt, queued, err)
		}
	}
	var automatic bool
	var priority int
	if err := db.QueryRow(`SELECT (payload->>'automatic')::boolean,priority FROM background_jobs WHERE job_type='audio_summary' AND resource_id=$1`, id).Scan(&automatic, &priority); err != nil || !automatic || priority != 10 {
		t.Fatalf("automatic=%v priority=%d err=%v", automatic, priority, err)
	}
}

func TestLibraryLargePageExplain(t *testing.T) {
	if testing.Short() {
		t.Skip("large query fixture")
	}
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	user := insertAIReportUser(t, db)
	if _, err := db.Exec(`INSERT INTO audio_transcriptions(filename,original_name,user_id,status,transcript_text)
 SELECT 'generated-'||g,'Generated '||g,$1,'completed',repeat('Generated transcript '||g||' '||md5(g::text)||' ',100)
 FROM generate_series(1,10000) g`, user); err != nil {
		t.Fatal(err)
	}
	defer db.Exec(`DELETE FROM audio_transcriptions WHERE user_id=$1`, user)
	if _, err := db.Exec(`ANALYZE audio_transcriptions`); err != nil {
		t.Fatal(err)
	}
	args := []any{user, nil, "audio", "", "", "all", "", "", nil, 20, 0}
	var plan json.RawMessage
	if err := db.GetContext(ctx, &plan, `EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) `+libraryPageQuery("desc"), args...); err != nil {
		t.Fatal(err)
	}
	var parsed []map[string]any
	if err := json.Unmarshal(plan, &parsed); err != nil {
		t.Fatal(err)
	}
	t.Logf("10,000 rows EXPLAIN execution_ms=%v planning_ms=%v", parsed[0]["Execution Time"], parsed[0]["Planning Time"])
	// Bound the response: the selected page returns at most 4096 source chars
	// per item, even though each stored transcript is much larger.
	items, total, err := db.ListLibraryItems(ctx, models.LibraryListParams{UserID: &user, ItemType: "audio", PerPage: 20})
	if err != nil || total != 10000 || len(items) != 20 {
		t.Fatalf("page size=%d total=%d err=%v", len(items), total, err)
	}
	for _, item := range items {
		if len([]rune(item.Excerpt)) > 200 || strings.Contains(item.Excerpt, "**") {
			t.Fatal("unbounded excerpt")
		}
	}
}

func TestLibraryMixedMediaAdditions(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	user := insertAIReportUser(t, db)
	video := insertAIReportTranscript(t, db, user)
	if _, err := db.Exec(`INSERT INTO summaries(transcript_id,model_used,summary_text,status) VALUES($1,'test/model',$2,'completed')`, video, `{"summary":"## Video **summary** [3]."}`); err != nil {
		t.Fatal(err)
	}
	pdf := uuid.NewString()
	if _, err := db.Exec(`INSERT INTO pdf_extractions(id,filename,original_name,text_content,user_id) VALUES($1,'test.pdf','Test PDF','Document opening text.',$2)`, pdf, user); err != nil {
		t.Fatal(err)
	}
	defer db.Exec(`DELETE FROM pdf_extractions WHERE id=$1`, pdf)
	empty := insertTestAudio(t, db, "failed")
	if _, err := db.Exec(`UPDATE audio_transcriptions SET user_id=$2 WHERE id=$1`, empty, user); err != nil {
		t.Fatal(err)
	}
	items, total, err := db.ListLibraryItems(ctx, models.LibraryListParams{UserID: &user})
	if err != nil || total != 3 {
		t.Fatalf("items=%+v total=%d err=%v", items, total, err)
	}
	for _, item := range items {
		if string(item.Collections) != "[]" || len(item.Waveform) != 0 {
			t.Fatalf("bad empty additions %+v", item)
		}
		want := ""
		if item.ID == video {
			want = "Video summary."
		}
		if item.ID == pdf {
			want = "Document opening text."
		}
		if item.Excerpt != want {
			t.Fatalf("%s excerpt=%q want %q", item.ItemType, item.Excerpt, want)
		}
	}
}

// A person pressing Summarize must not wait in the backfill's one-at-a-time line.
func TestQueueAudioSummaryPromotesQueuedBackfillJob(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	userID := createPasswordTestUser(t, db)
	audio := &models.AudioTranscription{ID: uuid.NewString(), ContentType: "voice_memo", SummaryStatus: "pending"}
	if _, err := db.ExecContext(ctx, `INSERT INTO audio_transcriptions(id,filename,original_name,status,user_id,transcript_text) VALUES($1,'a.m4a','a.m4a','completed',$2,'Some speech')`, audio.ID, userID); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		db.ExecContext(context.Background(), `DELETE FROM background_jobs WHERE resource_id=$1`, audio.ID)
		db.ExecContext(context.Background(), `DELETE FROM audio_transcriptions WHERE id=$1`, audio.ID)
	})
	if _, err := db.ExecContext(ctx, `INSERT INTO background_jobs(job_type,resource_id,payload,priority) VALUES('audio_summary',$1,'{"backfill":true}'::jsonb,10)`, audio.ID); err != nil {
		t.Fatal(err)
	}
	if err := db.QueueAudioSummary(ctx, audio, []byte(`{"audio_id":"person"}`)); err != nil {
		t.Fatal(err)
	}
	var priority int
	if err := db.GetContext(ctx, &priority, `SELECT priority FROM background_jobs WHERE job_type='audio_summary' AND resource_id=$1`, audio.ID); err != nil {
		t.Fatal(err)
	}
	if priority != 0 {
		t.Fatalf("priority = %d, want 0", priority)
	}
}
