CREATE TABLE IF NOT EXISTS audio_upload_sessions (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    object_key    TEXT NOT NULL UNIQUE,
    original_name TEXT NOT NULL,
    content_type  TEXT NOT NULL DEFAULT 'application/octet-stream',
    size_bytes    BIGINT NOT NULL,
    user_id       UUID REFERENCES users(id) ON DELETE CASCADE,
    api_key_id    UUID REFERENCES api_keys(id) ON DELETE CASCADE,
    status        TEXT NOT NULL DEFAULT 'pending',
    expires_at    TIMESTAMPTZ NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at  TIMESTAMPTZ,
    CHECK (status IN ('pending', 'completed', 'expired')),
    CHECK (user_id IS NOT NULL OR api_key_id IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS idx_audio_upload_sessions_actor
ON audio_upload_sessions (user_id, api_key_id, status, expires_at);
