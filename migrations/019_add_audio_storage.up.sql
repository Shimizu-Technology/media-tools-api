ALTER TABLE audio_transcriptions
ADD COLUMN IF NOT EXISTS audio_s3_key TEXT,
ADD COLUMN IF NOT EXISTS audio_s3_status TEXT NOT NULL DEFAULT 'pending',
ADD COLUMN IF NOT EXISTS audio_s3_size BIGINT NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_audio_transcriptions_audio_s3_key
ON audio_transcriptions (audio_s3_key);
