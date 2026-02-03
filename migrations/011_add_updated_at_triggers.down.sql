-- Migration 011 down: Remove updated_at triggers

DROP TRIGGER IF EXISTS update_transcripts_updated_at ON transcripts;
DROP TRIGGER IF EXISTS update_batches_updated_at ON batches;
DROP FUNCTION IF EXISTS update_updated_at_column();
