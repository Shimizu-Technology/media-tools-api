-- Keep the user's requested summary detail level on the media row as well as
-- in the queue payload. If a process crashes after the row becomes pending,
-- startup recovery can reconstruct the exact request without guessing.
ALTER TABLE audio_transcriptions
    ADD COLUMN summary_length VARCHAR(20) NOT NULL DEFAULT 'medium';

ALTER TABLE audio_transcriptions
    ADD CONSTRAINT check_audio_summary_length
    CHECK (summary_length IN ('short', 'medium', 'detailed'));
