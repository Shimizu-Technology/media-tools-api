ALTER TABLE audio_transcriptions
    DROP COLUMN IF EXISTS omitted_ranges,
    DROP COLUMN IF EXISTS quality_warning;
