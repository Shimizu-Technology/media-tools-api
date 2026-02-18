-- Widen youtube_id to TEXT to support non-YouTube video IDs (Vimeo, generic URLs).
-- Generic URL IDs are host+path strings that can exceed VARCHAR(20).
-- Note: Migration 021 (add clerk_id to users) is on the feature/clerk-auth-reliability branch.
ALTER TABLE transcripts ALTER COLUMN youtube_id TYPE TEXT;
