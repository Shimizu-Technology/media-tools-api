-- Migration 012 down: Remove status check constraints

ALTER TABLE transcripts DROP CONSTRAINT IF EXISTS check_transcript_status;
ALTER TABLE batches DROP CONSTRAINT IF EXISTS check_batch_status;
ALTER TABLE audio_transcriptions DROP CONSTRAINT IF EXISTS check_audio_status;
ALTER TABLE audio_transcriptions DROP CONSTRAINT IF EXISTS check_audio_summary_status;
ALTER TABLE pdf_extractions DROP CONSTRAINT IF EXISTS check_pdf_status;
ALTER TABLE webhook_deliveries DROP CONSTRAINT IF EXISTS check_webhook_delivery_status;
