-- Migration 010 down: Remove performance indexes

DROP INDEX IF EXISTS idx_summaries_transcript_created;
DROP INDEX IF EXISTS idx_summaries_created_at;
DROP INDEX IF EXISTS idx_api_keys_created_at;
DROP INDEX IF EXISTS idx_batches_created_at;
DROP INDEX IF EXISTS idx_batches_updated_at;
DROP INDEX IF EXISTS idx_transcripts_batch_status;
DROP INDEX IF EXISTS idx_transcripts_user_created;
DROP INDEX IF EXISTS idx_webhooks_created_at;
DROP INDEX IF EXISTS idx_webhook_deliveries_webhook_created;
DROP INDEX IF EXISTS idx_pdf_extractions_status;
DROP INDEX IF EXISTS idx_audio_transcriptions_filename;
DROP INDEX IF EXISTS idx_pdf_extractions_filename;
