-- Durable account deletion keeps the application database, object storage, and
-- Clerk identity in sync even when one provider is temporarily unavailable.
-- The raw Clerk ID and object keys are cleared after completion; the one-way
-- hash remains as a minimal tombstone so an already-issued token cannot
-- silently recreate the deleted application account.

CREATE TABLE account_deletion_requests (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    app_user_id      UUID NOT NULL,
    clerk_user_id    TEXT,
    clerk_user_hash  CHAR(64) NOT NULL UNIQUE,
    object_keys      JSONB NOT NULL DEFAULT '[]'::jsonb,
    status           VARCHAR(20) NOT NULL DEFAULT 'pending',
    cleanup_after    TIMESTAMPTZ NOT NULL,
    clerk_deleted_at TIMESTAMPTZ,
    completed_at     TIMESTAMPTZ,
    last_error       TEXT NOT NULL DEFAULT '',
    requested_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT account_deletion_status_check
        CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
    CONSTRAINT account_deletion_object_keys_check
        CHECK (jsonb_typeof(object_keys) = 'array')
);

CREATE INDEX idx_account_deletion_status
    ON account_deletion_requests(status, cleanup_after, requested_at);

DROP TRIGGER IF EXISTS update_account_deletion_requests_updated_at
    ON account_deletion_requests;
CREATE TRIGGER update_account_deletion_requests_updated_at
    BEFORE UPDATE ON account_deletion_requests
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

ALTER TABLE background_jobs DROP CONSTRAINT background_jobs_type_check;
ALTER TABLE background_jobs
    ADD CONSTRAINT background_jobs_type_check
    CHECK (job_type IN (
        'transcript_extraction',
        'summary_generation',
        'audio_transcription',
        'audio_summary',
        'audio_transcript_formatting',
        'account_deletion'
    ));
