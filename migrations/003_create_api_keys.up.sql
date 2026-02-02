-- Migration 003: Create api_keys table
-- API keys are hashed before storage (like passwords).
-- We keep a prefix for identification in the UI.

CREATE TABLE IF NOT EXISTS api_keys (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    key_hash     VARCHAR(64) NOT NULL UNIQUE,        -- SHA-256 hash of the key
    key_prefix   VARCHAR(12) NOT NULL,               -- First 8 chars + "..." for display
    name         VARCHAR(100) NOT NULL,
    active       BOOLEAN NOT NULL DEFAULT true,
    rate_limit   INTEGER NOT NULL DEFAULT 100,       -- Requests per hour
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_used_at TIMESTAMPTZ
);

-- Index for fast key lookups during authentication
CREATE INDEX IF NOT EXISTS idx_api_keys_key_hash ON api_keys(key_hash) WHERE active = true;
