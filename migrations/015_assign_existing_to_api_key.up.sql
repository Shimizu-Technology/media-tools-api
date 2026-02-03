-- Migration 015: Assign existing transcripts to the most recently created API key
-- This is a one-time data migration to claim existing content.

-- Assign all transcripts with NULL api_key_id to the most recent API key
UPDATE transcripts 
SET api_key_id = (SELECT id FROM api_keys ORDER BY created_at DESC LIMIT 1)
WHERE api_key_id IS NULL;

-- Assign all audio_transcriptions with NULL api_key_id to the most recent API key
UPDATE audio_transcriptions 
SET api_key_id = (SELECT id FROM api_keys ORDER BY created_at DESC LIMIT 1)
WHERE api_key_id IS NULL;

-- Assign all pdf_extractions with NULL api_key_id to the most recent API key
UPDATE pdf_extractions 
SET api_key_id = (SELECT id FROM api_keys ORDER BY created_at DESC LIMIT 1)
WHERE api_key_id IS NULL;
