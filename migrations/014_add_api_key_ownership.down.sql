-- Rollback Migration 014: Remove API key ownership

DROP INDEX IF EXISTS idx_transcripts_api_key_id;
DROP INDEX IF EXISTS idx_audio_transcriptions_api_key_id;
DROP INDEX IF EXISTS idx_pdf_extractions_api_key_id;

ALTER TABLE transcripts DROP COLUMN IF EXISTS api_key_id;
ALTER TABLE audio_transcriptions DROP COLUMN IF EXISTS api_key_id;
ALTER TABLE pdf_extractions DROP COLUMN IF EXISTS api_key_id;
