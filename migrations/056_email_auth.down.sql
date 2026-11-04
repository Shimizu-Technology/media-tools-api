-- Stop new binaries before rollback. Retain historical auth-email jobs as
-- failed records rather than allowing an old worker to claim unknown types.
DELETE FROM background_jobs WHERE job_type='auth_email';
ALTER TABLE background_jobs DROP CONSTRAINT background_jobs_type_check;
ALTER TABLE background_jobs ADD CONSTRAINT background_jobs_type_check CHECK
 (job_type IN ('transcript_extraction','summary_generation','audio_transcription','audio_summary','audio_transcript_formatting','account_deletion'));
DROP TABLE auth_email_outbox,auth_email_challenges,auth_failure_buckets,auth_events;
DROP INDEX auth_access_tokens_expiry;
DROP INDEX auth_refresh_tokens_expiry;
DROP TABLE auth_verified_emails;
