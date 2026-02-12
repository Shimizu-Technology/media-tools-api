ALTER TABLE audio_transcriptions
ADD COLUMN IF NOT EXISTS processing_stage TEXT NOT NULL DEFAULT 'queued',
ADD COLUMN IF NOT EXISTS processing_progress INTEGER NOT NULL DEFAULT 0,
ADD COLUMN IF NOT EXISTS retry_count INTEGER NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_audio_transcriptions_processing_stage
ON audio_transcriptions (processing_stage);
