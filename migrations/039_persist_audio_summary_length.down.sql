ALTER TABLE audio_transcriptions
    DROP CONSTRAINT IF EXISTS check_audio_summary_length,
    DROP COLUMN IF EXISTS summary_length;
