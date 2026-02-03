-- Migration 013 down: Revert language column size
-- Note: This may fail if existing data exceeds VARCHAR(10)

ALTER TABLE transcripts ALTER COLUMN language TYPE VARCHAR(10);
ALTER TABLE audio_transcriptions ALTER COLUMN language TYPE VARCHAR(10);
