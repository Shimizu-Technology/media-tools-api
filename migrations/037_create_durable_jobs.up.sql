-- Durable, multi-instance-safe background work. Workers claim rows with
-- FOR UPDATE SKIP LOCKED and keep a renewable lease while processing.

CREATE TABLE IF NOT EXISTS background_jobs (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_type         VARCHAR(40) NOT NULL,
    resource_id      UUID NOT NULL,
    payload          JSONB NOT NULL DEFAULT '{}'::jsonb,
    status           VARCHAR(20) NOT NULL DEFAULT 'queued',
    attempts         INTEGER NOT NULL DEFAULT 0,
    max_attempts     INTEGER NOT NULL DEFAULT 1,
    run_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    locked_by        TEXT,
    locked_at        TIMESTAMPTZ,
    lease_expires_at TIMESTAMPTZ,
    started_at       TIMESTAMPTZ,
    completed_at     TIMESTAMPTZ,
    last_error       TEXT NOT NULL DEFAULT '',
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT background_jobs_type_check
        CHECK (job_type IN (
            'transcript_extraction',
            'summary_generation',
            'audio_transcription',
            'audio_summary'
        )),
    CONSTRAINT background_jobs_status_check
        CHECK (status IN ('queued', 'running', 'completed', 'failed')),
    CONSTRAINT background_jobs_attempts_check
        CHECK (attempts >= 0 AND max_attempts > 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_background_jobs_active_resource
    ON background_jobs(job_type, resource_id)
    WHERE status IN ('queued', 'running');

CREATE INDEX IF NOT EXISTS idx_background_jobs_claim
    ON background_jobs(status, run_at, created_at)
    WHERE status IN ('queued', 'running');

CREATE INDEX IF NOT EXISTS idx_background_jobs_resource
    ON background_jobs(resource_id, job_type, created_at DESC);

DROP TRIGGER IF EXISTS update_background_jobs_updated_at ON background_jobs;
CREATE TRIGGER update_background_jobs_updated_at
    BEFORE UPDATE ON background_jobs
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
