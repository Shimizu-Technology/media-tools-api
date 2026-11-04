-- Stop upgraded workers before rollback. Remove only this new job type.
DROP TABLE backfill_run_jobs;
DROP TABLE backfill_runs;
DELETE FROM background_jobs WHERE job_type IN ('audio_waveform','admin_backfill');
ALTER TABLE background_jobs DROP CONSTRAINT background_jobs_type_check;
ALTER TABLE background_jobs ADD CONSTRAINT background_jobs_type_check CHECK
 (job_type IN ('transcript_extraction','summary_generation','audio_transcription','audio_summary','audio_transcript_formatting','account_deletion','auth_email')) NOT VALID;
DROP INDEX collection_items_media_lookup;
ALTER TABLE collections DROP COLUMN color;
DROP INDEX background_jobs_priority_ready;
ALTER TABLE background_jobs DROP COLUMN priority;
ALTER TABLE audio_transcriptions DROP COLUMN waveform, DROP COLUMN waveform_status;
