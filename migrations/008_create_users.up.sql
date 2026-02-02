-- Migration 008: Create users table and link to existing tables (MTA-20)
-- Users can register with email/password and get JWT tokens.
-- API keys, transcripts, audio, and PDFs can optionally be linked to users.

CREATE TABLE IF NOT EXISTS users (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email         VARCHAR(255) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    name          VARCHAR(255) NOT NULL DEFAULT '',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email ON users(email);

-- Link API keys to users (optional — existing keys without users still work)
ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES users(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_api_keys_user_id ON api_keys(user_id) WHERE user_id IS NOT NULL;

-- Link transcripts to users (optional)
ALTER TABLE transcripts ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES users(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_transcripts_user_id ON transcripts(user_id) WHERE user_id IS NOT NULL;

-- Link audio transcriptions to users (optional)
ALTER TABLE audio_transcriptions ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES users(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_audio_transcriptions_user_id ON audio_transcriptions(user_id) WHERE user_id IS NOT NULL;

-- Link PDF extractions to users (optional)
ALTER TABLE pdf_extractions ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES users(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_pdf_extractions_user_id ON pdf_extractions(user_id) WHERE user_id IS NOT NULL;

-- Workspace saved items
CREATE TABLE IF NOT EXISTS workspace_items (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    item_type   VARCHAR(20) NOT NULL,       -- 'transcript', 'audio', 'pdf'
    item_id     UUID NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_workspace_items_user_id ON workspace_items(user_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_workspace_items_unique ON workspace_items(user_id, item_type, item_id);
