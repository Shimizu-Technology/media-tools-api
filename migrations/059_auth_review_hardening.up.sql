-- Additive history: deleting/replacing a challenge never resets rolling limits.
CREATE TABLE auth_email_limits (
 id BIGSERIAL PRIMARY KEY,
 purpose TEXT NOT NULL CHECK (purpose IN ('signup','reset','email_change','verify')),
 email TEXT NOT NULL,
 kind TEXT NOT NULL CHECK (kind IN ('send','wrong')),
 created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX auth_email_limits_address_time ON auth_email_limits(purpose,email,kind,created_at);
-- Pending signups must supply a fresh password with their proof.
UPDATE auth_email_challenges SET password_hash='';

ALTER TABLE audio_transcriptions DROP CONSTRAINT check_audio_summary_status;
ALTER TABLE audio_transcriptions ADD CONSTRAINT check_audio_summary_status CHECK(summary_status IN ('none','pending','processing','completed','failed','skipped'));
ALTER TABLE audio_transcriptions DROP CONSTRAINT check_audio_formatting_status;
ALTER TABLE audio_transcriptions ADD CONSTRAINT check_audio_formatting_status CHECK(formatting_status IN ('none','pending','processing','completed','failed','skipped'));
