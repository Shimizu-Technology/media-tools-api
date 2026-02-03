-- Rollback Migration 015: Clear the api_key_id assignments
-- This can't fully rollback (we don't know the original state), so we just NULL them out.

UPDATE transcripts SET api_key_id = NULL WHERE api_key_id IS NOT NULL;
UPDATE audio_transcriptions SET api_key_id = NULL WHERE api_key_id IS NOT NULL;
UPDATE pdf_extractions SET api_key_id = NULL WHERE api_key_id IS NOT NULL;
