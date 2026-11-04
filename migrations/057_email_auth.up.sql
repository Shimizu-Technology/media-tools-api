-- Additive: existing accounts remain unverified until they prove their email.
-- Keep users unchanged: old deployed binaries use strict sqlx SELECT *.
CREATE TABLE auth_verified_emails (
 user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
 email TEXT NOT NULL,
 verified_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE auth_email_challenges (
 id UUID PRIMARY KEY,
 purpose TEXT NOT NULL CHECK (purpose IN ('signup','reset','email_change','verify')),
 email TEXT NOT NULL,
 user_id UUID REFERENCES users(id) ON DELETE CASCADE,
 code_hash CHAR(64) NOT NULL,
 password_hash TEXT NOT NULL DEFAULT '',
 credential_snapshot TEXT NOT NULL DEFAULT '',
 name TEXT NOT NULL DEFAULT '',
 attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 5),
 created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 expires_at TIMESTAMPTZ NOT NULL DEFAULT NOW()+INTERVAL '10 minutes',
 consumed_at TIMESTAMPTZ,
 UNIQUE (purpose,email)
);
CREATE TABLE auth_email_outbox (
 id UUID PRIMARY KEY,
 challenge_id UUID REFERENCES auth_email_challenges(id) ON DELETE CASCADE,
 user_id UUID REFERENCES users(id) ON DELETE CASCADE,
 sealed TEXT NOT NULL,
 expires_at TIMESTAMPTZ NOT NULL,
 sent_at TIMESTAMPTZ
);
ALTER TABLE background_jobs DROP CONSTRAINT background_jobs_type_check;
ALTER TABLE background_jobs ADD CONSTRAINT background_jobs_type_check CHECK
 (job_type IN ('transcript_extraction','summary_generation','audio_transcription','audio_summary','audio_transcript_formatting','account_deletion','auth_email')) NOT VALID;

-- Fixed-size keyed email identifiers, never raw addresses or passwords.
CREATE TABLE auth_failure_buckets (
 bucket_hash CHAR(64) PRIMARY KEY,
 failures INTEGER NOT NULL DEFAULT 1,
 started_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE auth_events (
 id BIGSERIAL PRIMARY KEY,
 user_id UUID REFERENCES users(id) ON DELETE SET NULL,
 event TEXT NOT NULL,
 created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX auth_events_user_time ON auth_events(user_id,created_at DESC);
CREATE INDEX auth_access_tokens_expiry ON auth_access_tokens(expires_at);
CREATE INDEX auth_refresh_tokens_expiry ON auth_refresh_tokens(expires_at);
