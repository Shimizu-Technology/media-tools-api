ALTER TABLE audio_transcriptions
    ADD COLUMN IF NOT EXISTS quality_warning TEXT NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS omitted_ranges JSONB NOT NULL DEFAULT '[]'::jsonb;
