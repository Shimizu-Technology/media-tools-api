-- Migration 010: Add performance indexes for common query patterns
-- These indexes optimize the queries identified during code review.

-- Summaries: Queries often fetch summaries by transcript_id, sorted by created_at
CREATE INDEX IF NOT EXISTS idx_summaries_transcript_created 
    ON summaries(transcript_id, created_at DESC);

-- Summaries: General sorting by created_at
CREATE INDEX IF NOT EXISTS idx_summaries_created_at 
    ON summaries(created_at DESC);

-- API Keys: List queries sort by created_at
CREATE INDEX IF NOT EXISTS idx_api_keys_created_at 
    ON api_keys(created_at DESC);

-- Batches: Queries sort by created_at and updated_at
CREATE INDEX IF NOT EXISTS idx_batches_created_at 
    ON batches(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_batches_updated_at 
    ON batches(updated_at DESC);

-- Transcripts: UpdateBatchCounts queries by batch_id and status together
CREATE INDEX IF NOT EXISTS idx_transcripts_batch_status 
    ON transcripts(batch_id, status) WHERE batch_id IS NOT NULL;

-- Transcripts: User workspace views need user_id + created_at
CREATE INDEX IF NOT EXISTS idx_transcripts_user_created 
    ON transcripts(user_id, created_at DESC) WHERE user_id IS NOT NULL;

-- Webhooks: List queries sort by created_at
CREATE INDEX IF NOT EXISTS idx_webhooks_created_at 
    ON webhooks(created_at DESC);

-- Webhook Deliveries: Queries filter by webhook_id and sort by created_at
CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_webhook_created 
    ON webhook_deliveries(webhook_id, created_at DESC);

-- PDF Extractions: Status filtering (for failed/pending extractions)
CREATE INDEX IF NOT EXISTS idx_pdf_extractions_status 
    ON pdf_extractions(status);

-- Audio/PDF: Filename lookups
CREATE INDEX IF NOT EXISTS idx_audio_transcriptions_filename 
    ON audio_transcriptions(filename);

CREATE INDEX IF NOT EXISTS idx_pdf_extractions_filename 
    ON pdf_extractions(filename);
