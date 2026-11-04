DROP TRIGGER IF EXISTS preserve_failed_audio_content ON audio_transcriptions;
DROP FUNCTION IF EXISTS preserve_failed_audio_content();
DROP TABLE IF EXISTS audio_chunk_checkpoints;
DROP TABLE IF EXISTS processing_preferences;
ALTER TABLE background_jobs ALTER COLUMN max_attempts SET DEFAULT 1;

ALTER TABLE audio_transcriptions DROP COLUMN title_manually_set;
