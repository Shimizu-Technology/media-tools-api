-- Migration 013: Increase language column size
-- yt-dlp can return language codes like "en-orig" or longer descriptors.
-- VARCHAR(10) is too restrictive.

ALTER TABLE transcripts ALTER COLUMN language TYPE VARCHAR(50);
ALTER TABLE audio_transcriptions ALTER COLUMN language TYPE VARCHAR(50);
