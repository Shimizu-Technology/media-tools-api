ALTER TABLE audio_transcriptions
    DROP CONSTRAINT IF EXISTS check_audio_summary_status;
UPDATE audio_transcriptions
SET summary_status = 'failed',
    summary_error_message = CASE
        WHEN summary_status = 'pending' THEN 'Summary was canceled by a database rollback.'
        ELSE summary_error_message
    END
WHERE summary_status = 'pending';
ALTER TABLE audio_transcriptions
    ADD CONSTRAINT check_audio_summary_status
    CHECK (summary_status IN ('none', 'processing', 'completed', 'failed'));
ALTER TABLE audio_transcriptions
    DROP COLUMN IF EXISTS summary_error_message,
    DROP COLUMN IF EXISTS summary_evidence;

ALTER TABLE transcript_chat_messages
    DROP COLUMN IF EXISTS citations;

ALTER TABLE summaries
    DROP COLUMN IF EXISTS evidence;

DROP TRIGGER IF EXISTS delete_pdf_media_segments ON pdf_extractions;
DROP TRIGGER IF EXISTS delete_audio_media_segments ON audio_transcriptions;
DROP TRIGGER IF EXISTS delete_transcript_media_segments ON transcripts;
DROP FUNCTION IF EXISTS delete_media_segments_for_item();
DROP TABLE IF EXISTS media_segments;
