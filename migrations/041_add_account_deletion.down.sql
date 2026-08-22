DELETE FROM background_jobs WHERE job_type = 'account_deletion';

ALTER TABLE background_jobs DROP CONSTRAINT background_jobs_type_check;
ALTER TABLE background_jobs
    ADD CONSTRAINT background_jobs_type_check
    CHECK (job_type IN (
        'transcript_extraction',
        'summary_generation',
        'audio_transcription',
        'audio_summary',
        'audio_transcript_formatting'
    ));

DROP TRIGGER IF EXISTS update_account_deletion_requests_updated_at
    ON account_deletion_requests;
DROP TABLE IF EXISTS account_deletion_requests;
