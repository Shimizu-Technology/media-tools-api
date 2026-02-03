-- Migration 009: Add summary fields to audio_transcriptions (MTA-22, MTA-24, MTA-25)
-- Supports AI summarization with content-type-aware prompts.

ALTER TABLE audio_transcriptions
    ADD COLUMN IF NOT EXISTS content_type    VARCHAR(30)  NOT NULL DEFAULT 'general',
    ADD COLUMN IF NOT EXISTS summary_text    TEXT         NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS key_points      JSONB        NOT NULL DEFAULT '[]',
    ADD COLUMN IF NOT EXISTS action_items    JSONB        NOT NULL DEFAULT '[]',
    ADD COLUMN IF NOT EXISTS decisions       JSONB        NOT NULL DEFAULT '[]',
    ADD COLUMN IF NOT EXISTS summary_model   VARCHAR(100) NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS summary_status  VARCHAR(20)  NOT NULL DEFAULT 'none';

-- Full-text search index on transcript_text and summary_text (MTA-25)
CREATE INDEX IF NOT EXISTS idx_audio_transcriptions_fts
    ON audio_transcriptions
    USING GIN (to_tsvector('english', transcript_text || ' ' || summary_text));

-- Index on content_type for filtering
CREATE INDEX IF NOT EXISTS idx_audio_transcriptions_content_type
    ON audio_transcriptions(content_type);
