DROP INDEX IF EXISTS idx_audio_transcriptions_audio_s3_key;

ALTER TABLE audio_transcriptions
DROP COLUMN IF EXISTS audio_s3_size,
DROP COLUMN IF EXISTS audio_s3_status,
DROP COLUMN IF EXISTS audio_s3_key;
