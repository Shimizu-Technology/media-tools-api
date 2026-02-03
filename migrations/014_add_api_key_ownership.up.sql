-- Migration 014: Add API key ownership to content tables
-- This allows filtering transcripts/audio/PDFs by the API key that created them.

-- Add api_key_id to transcripts
ALTER TABLE transcripts 
ADD COLUMN IF NOT EXISTS api_key_id UUID REFERENCES api_keys(id) ON DELETE SET NULL;

-- Add api_key_id to audio_transcriptions
ALTER TABLE audio_transcriptions 
ADD COLUMN IF NOT EXISTS api_key_id UUID REFERENCES api_keys(id) ON DELETE SET NULL;

-- Add api_key_id to pdf_extractions
ALTER TABLE pdf_extractions 
ADD COLUMN IF NOT EXISTS api_key_id UUID REFERENCES api_keys(id) ON DELETE SET NULL;

-- Indexes for filtering by API key
CREATE INDEX IF NOT EXISTS idx_transcripts_api_key_id ON transcripts(api_key_id);
CREATE INDEX IF NOT EXISTS idx_audio_transcriptions_api_key_id ON audio_transcriptions(api_key_id);
CREATE INDEX IF NOT EXISTS idx_pdf_extractions_api_key_id ON pdf_extractions(api_key_id);
