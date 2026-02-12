DROP INDEX IF EXISTS idx_audio_transcriptions_processing_stage;

ALTER TABLE audio_transcriptions
DROP COLUMN IF EXISTS retry_count,
DROP COLUMN IF EXISTS processing_progress,
DROP COLUMN IF EXISTS processing_stage;
