package database

import (
	"context"
	"testing"
	"time"
)

func TestPipelineFailureAndExpiredLeaseAreBounded(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	for _, expired := range []bool{false, true} {
		id := insertTestAudio(t, db, "pending")
		if _, err := db.ExecContext(ctx, `UPDATE audio_transcriptions SET transcript_text='Previous speech', summary_text='Previous summary' WHERE id=$1`, id); err != nil {
			t.Fatal(err)
		}
		var jobID string
		if err := db.QueryRowContext(ctx, `UPDATE background_jobs SET status='running',locked_by='pipeline-test',attempts=max_attempts,lease_expires_at=NOW()-INTERVAL '1 second' WHERE resource_id=$1 RETURNING id`, id).Scan(&jobID); err != nil {
			t.Fatal(err)
		}
		if expired {
			if _, err := db.ClaimBackgroundJob(ctx, "replacement", time.Minute); err != nil {
				t.Fatal(err)
			}
		} else {
			if err := db.FailBackgroundJob(ctx, jobID, "pipeline-test", "simulated panic or read failure"); err != nil {
				t.Fatal(err)
			}
		}
		var status, stage, text, summary string
		if err := db.QueryRowContext(ctx, `SELECT status,processing_stage,transcript_text,summary_text FROM audio_transcriptions WHERE id=$1`, id).Scan(&status, &stage, &text, &summary); err != nil {
			t.Fatal(err)
		}
		if status != "failed" || stage != "failed" || text != "Previous speech" || summary != "Previous summary" {
			t.Fatalf("expired=%t: %q %q %q %q", expired, status, stage, text, summary)
		}
		var queueStatus string
		if err := db.QueryRowContext(ctx, `SELECT status FROM background_jobs WHERE id=$1`, jobID).Scan(&queueStatus); err != nil {
			t.Fatal(err)
		}
		if queueStatus != "failed" {
			t.Fatal(queueStatus)
		}
	}
}

func TestAutomaticSummaryPreferenceAndRenameProtection(t *testing.T) {
	t.Setenv("AUTOMATIC_AUDIO_ENRICHMENT_ENABLED", "true")
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	var userID string
	if err := db.QueryRowContext(ctx, `INSERT INTO users(email,password_hash) VALUES(gen_random_uuid()::text || '@pipeline.test','unused') RETURNING id`).Scan(&userID); err != nil {
		t.Fatal(err)
	}
	defer db.ExecContext(ctx, `DELETE FROM users WHERE id=$1`, userID)
	if _, err := db.ExecContext(ctx, `INSERT INTO processing_preferences(user_id,automatic_summaries) VALUES($1,false)`, userID); err != nil {
		t.Fatal(err)
	}
	id := insertTestAudio(t, db, "processing")
	if _, err := db.ExecContext(ctx, `UPDATE audio_transcriptions SET user_id=$2 WHERE id=$1`, id, userID); err != nil {
		t.Fatal(err)
	}
	at, err := db.GetAudioTranscription(ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	at.Status = "completed"
	at.TranscriptText = "Call tomorrow morning."
	at.WordCount = 3
	if saved, err := db.CompleteAudioTranscriptionWithSegments(ctx, at, nil); err != nil || !saved {
		t.Fatalf("saved=%t err=%v", saved, err)
	}
	var titleOnly bool
	if err := db.QueryRowContext(ctx, `SELECT (payload->>'title_only')::boolean FROM background_jobs WHERE resource_id=$1 AND job_type='audio_summary'`, id).Scan(&titleOnly); err != nil {
		t.Fatal(err)
	}
	if !titleOnly {
		t.Fatal("disabled summaries queued a summary")
	}
	if _, err := db.RenameAudioTranscriptionForActor(ctx, id, &userID, nil, "My personal title"); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `UPDATE audio_transcriptions SET original_name='Automatic title' WHERE id=$1 AND NOT title_manually_set`, id); err != nil {
		t.Fatal(err)
	}
	got, err := db.GetAudioTranscription(ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	if got.OriginalName != "My personal title" {
		t.Fatal("rename overwritten")
	}
}

func TestFailedRetranscriptionKeepsPriorResultAndChat(t *testing.T) {
	db := openPostgresIntegrationDB(t)
	ctx := context.Background()
	var userID string
	if err := db.QueryRowContext(ctx, `INSERT INTO users(email,password_hash) VALUES(gen_random_uuid()::text || '@pipeline.test','unused') RETURNING id`).Scan(&userID); err != nil {
		t.Fatal(err)
	}
	defer db.ExecContext(ctx, `DELETE FROM users WHERE id=$1`, userID)
	id := insertTestAudio(t, db, "completed")
	if _, err := db.ExecContext(ctx, `UPDATE audio_transcriptions SET user_id=$2,transcript_text='Prior transcript',summary_text='Prior summary',summary_status='completed' WHERE id=$1`, id, userID); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `INSERT INTO transcript_chat_sessions(item_type,item_id,user_id) VALUES('audio',$1,$2)`, id, userID); err != nil {
		t.Fatal(err)
	}
	defer db.ExecContext(ctx, `DELETE FROM transcript_chat_sessions WHERE item_id=$1`, id)
	at, err := db.GetAudioTranscription(ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	at.Status = "pending"
	at.ProcessingStage = "queued"
	if _, prepared, err := db.PrepareAudioRetranscriptionForActor(ctx, at, &userID, nil); err != nil || !prepared {
		t.Fatalf("prepared=%t err=%v", prepared, err)
	}
	var jobID string
	if err := db.QueryRowContext(ctx, `UPDATE background_jobs SET status='running',locked_by='test-retranscribe' WHERE resource_id=$1 AND job_type='audio_transcription' RETURNING id`, id).Scan(&jobID); err != nil {
		t.Fatal(err)
	}
	if err := db.FailBackgroundJob(ctx, jobID, "test-retranscribe", "simulated outage exhausted"); err != nil {
		t.Fatal(err)
	}
	got, err := db.GetAudioTranscription(ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	var chats int
	if err := db.QueryRowContext(ctx, `SELECT count(*) FROM transcript_chat_sessions WHERE item_id=$1`, id).Scan(&chats); err != nil {
		t.Fatal(err)
	}
	if got.TranscriptText != "Prior transcript" || got.SummaryText != "Prior summary" || chats != 1 {
		t.Fatal("prior result or chat was lost")
	}
}
