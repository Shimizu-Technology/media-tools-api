-- Preserve source evidence so summaries and chat can cite the exact moment or
-- page that supports an answer. The parent relationship is polymorphic, so
-- ownership and deletion are enforced by the application.

CREATE TABLE IF NOT EXISTS media_segments (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    item_type   VARCHAR(20) NOT NULL,
    item_id     UUID NOT NULL,
    ordinal     INTEGER NOT NULL,
    start_ms    BIGINT,
    end_ms      BIGINT,
    page_number INTEGER,
    text        TEXT NOT NULL,
    search_vector TSVECTOR GENERATED ALWAYS AS (
        to_tsvector('simple'::regconfig, COALESCE(text, ''))
    ) STORED,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT media_segments_item_type_check
        CHECK (item_type IN ('transcript', 'audio', 'pdf')),
    CONSTRAINT media_segments_ordinal_check
        CHECK (ordinal >= 0),
    CONSTRAINT media_segments_time_check
        CHECK (
            (start_ms IS NULL AND end_ms IS NULL)
            OR (start_ms IS NOT NULL AND end_ms IS NOT NULL AND start_ms >= 0 AND end_ms >= start_ms)
        ),
    CONSTRAINT media_segments_page_check
        CHECK (page_number IS NULL OR page_number > 0),
    UNIQUE (item_type, item_id, ordinal)
);

CREATE INDEX IF NOT EXISTS idx_media_segments_item
    ON media_segments(item_type, item_id, ordinal);
CREATE INDEX IF NOT EXISTS idx_media_segments_search
    ON media_segments USING GIN(search_vector);

CREATE OR REPLACE FUNCTION delete_media_segments_for_item()
RETURNS TRIGGER AS $$
BEGIN
    DELETE FROM media_segments
    WHERE item_type = TG_ARGV[0] AND item_id = OLD.id;
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS delete_transcript_media_segments ON transcripts;
CREATE TRIGGER delete_transcript_media_segments
    AFTER DELETE ON transcripts
    FOR EACH ROW EXECUTE FUNCTION delete_media_segments_for_item('transcript');

DROP TRIGGER IF EXISTS delete_audio_media_segments ON audio_transcriptions;
CREATE TRIGGER delete_audio_media_segments
    AFTER DELETE ON audio_transcriptions
    FOR EACH ROW EXECUTE FUNCTION delete_media_segments_for_item('audio');

DROP TRIGGER IF EXISTS delete_pdf_media_segments ON pdf_extractions;
CREATE TRIGGER delete_pdf_media_segments
    AFTER DELETE ON pdf_extractions
    FOR EACH ROW EXECUTE FUNCTION delete_media_segments_for_item('pdf');

ALTER TABLE summaries
    ADD COLUMN IF NOT EXISTS evidence JSONB NOT NULL DEFAULT '{}'::jsonb;

ALTER TABLE transcript_chat_messages
    ADD COLUMN IF NOT EXISTS citations JSONB NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE audio_transcriptions
    ADD COLUMN IF NOT EXISTS summary_evidence JSONB NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS summary_error_message TEXT NOT NULL DEFAULT '';

ALTER TABLE audio_transcriptions
    DROP CONSTRAINT IF EXISTS check_audio_summary_status;
ALTER TABLE audio_transcriptions
    ADD CONSTRAINT check_audio_summary_status
    CHECK (summary_status IN ('none', 'pending', 'processing', 'completed', 'failed'));
