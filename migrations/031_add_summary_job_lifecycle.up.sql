-- Persist transcript summary jobs so clients can observe failures and the
-- worker pool can recover interrupted work after a restart.

ALTER TABLE summaries
    ADD COLUMN IF NOT EXISTS content_type VARCHAR(30) NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS status VARCHAR(20) NOT NULL DEFAULT 'completed',
    ADD COLUMN IF NOT EXISTS error_message TEXT NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

UPDATE summaries
SET status = CASE WHEN summary_text = '' THEN 'failed' ELSE 'completed' END;

ALTER TABLE summaries
    DROP CONSTRAINT IF EXISTS check_summary_status;
ALTER TABLE summaries
    ADD CONSTRAINT check_summary_status
    CHECK (status IN ('pending', 'processing', 'completed', 'failed'));

CREATE INDEX IF NOT EXISTS idx_summaries_status_created
    ON summaries(status, created_at);

DROP TRIGGER IF EXISTS update_summaries_updated_at ON summaries;
CREATE TRIGGER update_summaries_updated_at
    BEFORE UPDATE ON summaries
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
