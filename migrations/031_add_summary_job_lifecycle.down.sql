DROP TRIGGER IF EXISTS update_summaries_updated_at ON summaries;
DROP INDEX IF EXISTS idx_summaries_status_created;

ALTER TABLE summaries
    DROP CONSTRAINT IF EXISTS check_summary_status,
    DROP COLUMN IF EXISTS updated_at,
    DROP COLUMN IF EXISTS error_message,
    DROP COLUMN IF EXISTS status,
    DROP COLUMN IF EXISTS content_type;
