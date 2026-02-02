-- Rollback Migration 004
ALTER TABLE transcripts DROP COLUMN IF EXISTS batch_id;
DROP TABLE IF EXISTS batches;
