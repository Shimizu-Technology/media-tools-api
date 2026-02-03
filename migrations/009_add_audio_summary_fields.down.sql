-- Rollback migration 009
DROP INDEX IF EXISTS idx_audio_transcriptions_fts;
DROP INDEX IF EXISTS idx_audio_transcriptions_content_type;

ALTER TABLE audio_transcriptions
    DROP COLUMN IF EXISTS content_type,
    DROP COLUMN IF EXISTS summary_text,
    DROP COLUMN IF EXISTS key_points,
    DROP COLUMN IF EXISTS action_items,
    DROP COLUMN IF EXISTS decisions,
    DROP COLUMN IF EXISTS summary_model,
    DROP COLUMN IF EXISTS summary_status;
