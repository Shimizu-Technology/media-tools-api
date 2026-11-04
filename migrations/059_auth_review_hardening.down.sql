ALTER TABLE auth_password_credentials DROP COLUMN IF EXISTS slow_guess_at;
UPDATE audio_transcriptions SET summary_status='failed' WHERE summary_status='skipped';
UPDATE audio_transcriptions SET formatting_status='failed' WHERE formatting_status='skipped';
ALTER TABLE audio_transcriptions DROP CONSTRAINT check_audio_summary_status;
ALTER TABLE audio_transcriptions ADD CONSTRAINT check_audio_summary_status CHECK(summary_status IN ('none','pending','processing','completed','failed'));
ALTER TABLE audio_transcriptions DROP CONSTRAINT check_audio_formatting_status;
ALTER TABLE audio_transcriptions ADD CONSTRAINT check_audio_formatting_status CHECK(formatting_status IN ('none','pending','processing','completed','failed'));
DROP TABLE IF EXISTS auth_email_limits;
