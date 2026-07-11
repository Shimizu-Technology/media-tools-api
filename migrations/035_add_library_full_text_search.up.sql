ALTER TABLE transcripts
    ADD COLUMN IF NOT EXISTS search_vector TSVECTOR GENERATED ALWAYS AS (
        to_tsvector('simple'::regconfig, COALESCE(title, '') || ' ' || COALESCE(channel_name, '') || ' ' || COALESCE(transcript_text, ''))
    ) STORED;

ALTER TABLE audio_transcriptions
    ADD COLUMN IF NOT EXISTS search_vector TSVECTOR GENERATED ALWAYS AS (
        to_tsvector('simple'::regconfig,
            COALESCE(original_name, '') || ' ' || COALESCE(language, '') || ' ' ||
            COALESCE(transcript_text, '') || ' ' || COALESCE(summary_text, '') || ' ' ||
            COALESCE(key_points::text, '') || ' ' || COALESCE(action_items::text, '') || ' ' || COALESCE(decisions::text, ''))
    ) STORED;

ALTER TABLE pdf_extractions
    ADD COLUMN IF NOT EXISTS search_vector TSVECTOR GENERATED ALWAYS AS (
        to_tsvector('simple'::regconfig, COALESCE(original_name, '') || ' ' || COALESCE(text_content, ''))
    ) STORED;

ALTER TABLE summaries
    ADD COLUMN IF NOT EXISTS search_vector TSVECTOR GENERATED ALWAYS AS (
        to_tsvector('simple'::regconfig, COALESCE(summary_text, '') || ' ' || COALESCE(key_points::text, ''))
    ) STORED;

CREATE INDEX IF NOT EXISTS idx_transcripts_search_vector ON transcripts USING GIN(search_vector);
CREATE INDEX IF NOT EXISTS idx_audio_transcriptions_search_vector ON audio_transcriptions USING GIN(search_vector);
CREATE INDEX IF NOT EXISTS idx_pdf_extractions_search_vector ON pdf_extractions USING GIN(search_vector);
CREATE INDEX IF NOT EXISTS idx_summaries_search_vector ON summaries USING GIN(search_vector);
