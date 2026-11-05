package database

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/Shimizu-Technology/media-tools-api/internal/models"
	"github.com/google/uuid"
)

func TestReviewWorkspaceBadWaveformAndCollectionScopes(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	user := insertAIReportUser(t, db)
	key := uuid.NewString()
	if _, err := db.Exec(`INSERT INTO api_keys(id,key_hash,key_prefix,name,user_id) VALUES($1,$2,'test','Key',$3)`, key, uuid.NewString(), user); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Exec(`DELETE FROM api_keys WHERE id=$1`, key) })
	id := insertTestAudio(t, db, "completed")
	bad := insertTestAudio(t, db, "completed")
	peaks, _ := json.Marshal(make([]int, 200))
	if _, err := db.Exec(`UPDATE audio_transcriptions SET user_id=$2,title_manually_set=true,waveform=$3::jsonb WHERE id=$1`, id, user, string(peaks)); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`UPDATE audio_transcriptions SET user_id=$2,waveform=to_jsonb(array_fill('bad'::text,ARRAY[200])) WHERE id=$1`, bad, user); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO workspace_items(user_id,item_type,item_id) VALUES($1,'audio',$2)`, user, id); err != nil {
		t.Fatal(err)
	}
	workspace, err := db.GetWorkspaceAudio(ctx, user)
	if err != nil || len(workspace) != 1 || workspace[0].ID != id || len(workspace[0].Waveform) == 0 {
		t.Fatalf("workspace scan %+v %v", workspace, err)
	}
	// Exercise all projections that formerly could encounter new/internal columns.
	if _, err := db.GetAudioTranscription(ctx, id); err != nil {
		t.Fatal(err)
	}
	if _, err := db.GetAudioTranscriptionForActor(ctx, id, &user, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := db.RenameAudioTranscriptionForActor(ctx, id, &user, nil, "Chosen name"); err != nil {
		t.Fatal(err)
	}
	var collection string
	if err := db.QueryRow(`INSERT INTO collections(name,api_key_id) VALUES('Key only',$1) RETURNING id`, key).Scan(&collection); err != nil {
		t.Fatal(err)
	}
	defer db.Exec(`DELETE FROM collections WHERE id=$1`, collection)
	if _, err := db.AddCollectionItems(ctx, collection, []models.CollectionItemInput{{ItemType: "audio", ItemID: id}}); err != nil {
		t.Fatal(err)
	}
	rows, total, err := db.ListLibraryItems(ctx, models.LibraryListParams{UserID: &user})
	if err != nil || total != 2 {
		t.Fatalf("bad waveform broke page %d %v", total, err)
	}
	for _, row := range rows {
		if string(row.Collections) != "[]" {
			t.Fatal("key-only collection leaked into account badge")
		}
		if row.ID == bad && len(row.Waveform) != 0 {
			t.Fatal("bad waveform was not omitted")
		}
	}
	accountCollections, err := db.ListCollections(ctx, &user, nil)
	if err != nil || len(accountCollections) != 0 {
		t.Fatalf("account collection scope %+v %v", accountCollections, err)
	}
	keyCollections, err := db.ListCollections(ctx, nil, &key)
	if err != nil || len(keyCollections) != 1 {
		t.Fatalf("classic key collection scope %+v %v", keyCollections, err)
	}
}

func TestReviewOrphanedWaveformPendingIsResumable(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	id := insertTestAudio(t, db, "completed")
	if _, err := db.Exec(`UPDATE audio_transcriptions SET audio_s3_key='test/source',audio_s3_status='uploaded',waveform_status='pending' WHERE id=$1`, id); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO background_jobs(job_type,resource_id,status,last_error) VALUES('audio_waveform',$1,'failed','unknown job type: audio_waveform')`, id); err != nil {
		t.Fatal(err)
	}
	candidates, err := db.ListBackfillCandidates(ctx, "waveforms", "")
	if err != nil {
		t.Fatal(err)
	}
	var candidate *BackfillCandidate
	for i := range candidates {
		if candidates[i].ID == id {
			candidate = &candidates[i]
		}
	}
	if candidate == nil {
		t.Fatal("orphaned pending row not eligible")
	}
	for attempt := 0; attempt < 2; attempt++ {
		queued, err := db.QueueBackfillCandidate(ctx, "waveforms", "", *candidate, "", false)
		if err != nil || queued != (attempt == 0) {
			t.Fatalf("resumption %v %v", queued, err)
		}
	}
}

func TestReviewExpiredMaintenanceReclaimedBeforeSiblings(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	// Isolate only this test DB's queue, restoring all unrelated fixture timings.
	var baseline []models.BackgroundJob
	if err := db.Select(&baseline, `SELECT `+backgroundJobColumns+` FROM background_jobs WHERE status IN ('queued','running')`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`UPDATE background_jobs SET run_at=NOW()+INTERVAL '1 day',lease_expires_at=NOW()+INTERVAL '1 day' WHERE status IN ('queued','running')`); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		for _, job := range baseline {
			db.Exec(`UPDATE background_jobs SET run_at=$2,lease_expires_at=$3 WHERE id=$1`, job.ID, job.RunAt, job.LeaseExpiresAt)
		}
	})
	old, sibling, anotherExpired := uuid.NewString(), uuid.NewString(), uuid.NewString()
	for _, id := range []string{old, sibling, anotherExpired} {
		defer db.Exec(`DELETE FROM background_jobs WHERE resource_id=$1`, id)
	}
	if _, err := db.Exec(`INSERT INTO background_jobs(job_type,resource_id,priority,status,lease_expires_at,attempts) VALUES('audio_waveform',$1,10,'running',NOW()-INTERVAL '1 minute',1)`, old); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO background_jobs(job_type,resource_id,priority) VALUES('audio_waveform',$1,5)`, sibling); err != nil {
		t.Fatal(err)
	}
	job, err := db.ClaimBackgroundJob(ctx, "replacement", time.Minute)
	if err != nil || job == nil || job.ResourceID != old {
		t.Fatalf("expired maintenance lost to sibling: %+v %v", job, err)
	}
	if _, err := db.Exec(`INSERT INTO background_jobs(job_type,resource_id,priority,status,lease_expires_at,attempts) VALUES('audio_waveform',$1,10,'running',NOW()-INTERVAL '1 minute',1)`, anotherExpired); err != nil {
		t.Fatal(err)
	}
	next, err := db.ClaimBackgroundJob(ctx, "idle", time.Minute)
	if err != nil || next != nil {
		t.Fatalf("maintenance slot violated %+v %v", next, err)
	}
	wake, err := db.NextBackgroundJobWake(ctx)
	if err != nil || wake == nil || time.Until(*wake) < 30*time.Second {
		t.Fatalf("past wake causes polling: %v %v", wake, err)
	}
}
