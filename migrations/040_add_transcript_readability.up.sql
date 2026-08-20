-- Keep the source transcript immutable and store the readability pass beside it.
-- Formatting is intentionally its own durable job: a provider outage can never
-- turn an otherwise valid Whisper transcription into a failed recording.
ALTER TABLE audio_transcriptions
    ADD COLUMN formatted_transcript_text TEXT NOT NULL DEFAULT '',
    ADD COLUMN formatting_status VARCHAR(20) NOT NULL DEFAULT 'none',
    ADD COLUMN formatting_model VARCHAR(120) NOT NULL DEFAULT '',
    ADD COLUMN formatting_version VARCHAR(40) NOT NULL DEFAULT '',
    ADD COLUMN formatting_error_message TEXT NOT NULL DEFAULT '';

ALTER TABLE audio_transcriptions
    ADD CONSTRAINT check_audio_formatting_status
    CHECK (formatting_status IN ('none', 'pending', 'processing', 'completed', 'failed'));

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
