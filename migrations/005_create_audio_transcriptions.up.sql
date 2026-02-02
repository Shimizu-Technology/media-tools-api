-- Migration 005: Create audio_transcriptions table (MTA-16)
-- Stores audio file transcription results via OpenAI Whisper API.

CREATE TABLE IF NOT EXISTS audio_transcriptions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    filename        VARCHAR(255) NOT NULL,                      -- Stored filename (UUID-based)
    original_name   VARCHAR(500) NOT NULL,                      -- User's original filename
    duration        FLOAT NOT NULL DEFAULT 0,                   -- Audio duration in seconds
    language        VARCHAR(10) NOT NULL DEFAULT '',             -- Detected language code
    transcript_text TEXT NOT NULL DEFAULT '',                    -- Full transcription text
    word_count      INTEGER NOT NULL DEFAULT 0,                 -- Word count of transcript
    status          VARCHAR(20) NOT NULL DEFAULT 'pending',     -- pending, processing, completed, failed
    error_message   TEXT NOT NULL DEFAULT '',                    -- Error details if failed
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index on status for filtering
CREATE INDEX IF NOT EXISTS idx_audio_transcriptions_status ON audio_transcriptions(status);

-- Index on created_at for sorting
CREATE INDEX IF NOT EXISTS idx_audio_transcriptions_created_at ON audio_transcriptions(created_at DESC);
