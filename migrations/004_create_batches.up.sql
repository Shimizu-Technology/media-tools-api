-- Migration 004: Create batches table for batch processing (MTA-8)
-- A batch groups multiple transcript extraction requests together.
-- Users submit an array of YouTube URLs and get a single batch ID to track progress.

CREATE TABLE IF NOT EXISTS batches (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    status          VARCHAR(20) NOT NULL DEFAULT 'pending',     -- pending, processing, completed, failed
    total_count     INTEGER NOT NULL DEFAULT 0,                 -- Total URLs submitted
    completed_count INTEGER NOT NULL DEFAULT 0,                 -- Successfully completed
    failed_count    INTEGER NOT NULL DEFAULT 0,                 -- Failed extractions
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Add batch_id to transcripts (nullable — single transcripts don't need a batch)
ALTER TABLE transcripts ADD COLUMN IF NOT EXISTS batch_id UUID REFERENCES batches(id) ON DELETE SET NULL;

-- Index for looking up transcripts by batch
CREATE INDEX IF NOT EXISTS idx_transcripts_batch_id ON transcripts(batch_id) WHERE batch_id IS NOT NULL;

-- Index on batch status for filtering
CREATE INDEX IF NOT EXISTS idx_batches_status ON batches(status);
