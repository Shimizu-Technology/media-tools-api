-- Migration 012: Add check constraints for status fields
-- These constraints ensure only valid status values are stored.

-- Transcripts status constraint
ALTER TABLE transcripts 
    ADD CONSTRAINT check_transcript_status 
    CHECK (status IN ('pending', 'processing', 'completed', 'failed'));

-- Batches status constraint
ALTER TABLE batches 
    ADD CONSTRAINT check_batch_status 
    CHECK (status IN ('pending', 'processing', 'completed', 'failed'));

-- Audio transcriptions status constraint
ALTER TABLE audio_transcriptions 
    ADD CONSTRAINT check_audio_status 
    CHECK (status IN ('pending', 'processing', 'completed', 'failed'));

-- Audio transcriptions summary_status constraint
ALTER TABLE audio_transcriptions 
    ADD CONSTRAINT check_audio_summary_status 
    CHECK (summary_status IN ('none', 'processing', 'completed', 'failed'));

-- PDF extractions status constraint
ALTER TABLE pdf_extractions 
    ADD CONSTRAINT check_pdf_status 
    CHECK (status IN ('pending', 'processing', 'completed', 'failed'));

-- Webhook deliveries status constraint
ALTER TABLE webhook_deliveries 
    ADD CONSTRAINT check_webhook_delivery_status 
    CHECK (status IN ('pending', 'success', 'failed'));
