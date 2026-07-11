DROP INDEX IF EXISTS idx_summaries_search_vector;
DROP INDEX IF EXISTS idx_pdf_extractions_search_vector;
DROP INDEX IF EXISTS idx_audio_transcriptions_search_vector;
DROP INDEX IF EXISTS idx_transcripts_search_vector;

ALTER TABLE summaries DROP COLUMN IF EXISTS search_vector;
ALTER TABLE pdf_extractions DROP COLUMN IF EXISTS search_vector;
ALTER TABLE audio_transcriptions DROP COLUMN IF EXISTS search_vector;
ALTER TABLE transcripts DROP COLUMN IF EXISTS search_vector;
