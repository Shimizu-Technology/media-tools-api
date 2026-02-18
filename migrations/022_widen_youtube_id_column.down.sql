-- Revert youtube_id back to VARCHAR(20).
-- Uses LEFT() to truncate any values longer than 20 chars (e.g., Vimeo/generic IDs).
ALTER TABLE transcripts ALTER COLUMN youtube_id TYPE VARCHAR(20) USING LEFT(youtube_id, 20);
