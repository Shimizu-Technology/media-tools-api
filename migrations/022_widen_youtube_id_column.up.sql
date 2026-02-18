-- Widen youtube_id to TEXT to support non-YouTube video IDs (Vimeo, generic URLs).
-- Generic URL IDs are host+path strings that can exceed VARCHAR(20).
ALTER TABLE transcripts ALTER COLUMN youtube_id TYPE TEXT;
