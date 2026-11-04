ALTER TABLE audio_transcriptions ADD COLUMN title_manually_set boolean NOT NULL DEFAULT false;
-- Conservatively protect historical names, including renames predating this flag.
UPDATE audio_transcriptions SET title_manually_set=true;
ALTER TABLE background_jobs ALTER COLUMN max_attempts SET DEFAULT 5;
UPDATE background_jobs SET max_attempts=5 WHERE status IN ('queued','running') AND max_attempts=1 AND job_type <> 'account_deletion';
CREATE TABLE audio_chunk_checkpoints (
 audio_id uuid NOT NULL REFERENCES audio_transcriptions(id) ON DELETE CASCADE,
 content_hash text NOT NULL,
 result jsonb NOT NULL,
 PRIMARY KEY(audio_id, content_hash)
);
CREATE TABLE processing_preferences (
 user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
 automatic_summaries boolean NOT NULL DEFAULT true
);
-- Keep the last usable result until its replacement commits successfully.
CREATE FUNCTION preserve_failed_audio_content() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.status='failed' AND OLD.transcript_text <> '' THEN
 NEW.transcript_text=OLD.transcript_text; NEW.word_count=OLD.word_count;
 NEW.duration=OLD.duration; NEW.language=OLD.language;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER preserve_failed_audio_content BEFORE UPDATE ON audio_transcriptions
 FOR EACH ROW EXECUTE FUNCTION preserve_failed_audio_content();
