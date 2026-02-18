-- Revert youtube_id back to VARCHAR(20).
-- Note: existing rows with values longer than 20 chars will cause this to fail.
ALTER TABLE transcripts ALTER COLUMN youtube_id TYPE VARCHAR(20);
