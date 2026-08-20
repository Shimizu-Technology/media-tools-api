DELETE FROM background_jobs WHERE job_type = 'audio_transcript_formatting';

ALTER TABLE background_jobs DROP CONSTRAINT background_jobs_type_check;
ALTER TABLE background_jobs
    ADD CONSTRAINT background_jobs_type_check
    CHECK (job_type IN (
        'transcript_extraction',
        'summary_generation',
        'audio_transcription',
        'audio_summary'
    ));

ALTER TABLE audio_transcriptions DROP CONSTRAINT check_audio_formatting_status;
ALTER TABLE audio_transcriptions
    DROP COLUMN formatting_error_message,
    DROP COLUMN formatting_version,
    DROP COLUMN formatting_model,
    DROP COLUMN formatting_status,
    DROP COLUMN formatted_transcript_text;
