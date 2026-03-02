-- Migration 025: Scope chat sessions by user ownership as well as API keys.
-- This prevents JWT-authenticated users from sharing NULL api_key_id sessions.

ALTER TABLE transcript_chat_sessions
    ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES users(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_chat_sessions_user_id
    ON transcript_chat_sessions(user_id);

-- Legacy sessions created without an owner cannot be safely attributed.
DELETE FROM transcript_chat_sessions
WHERE user_id IS NULL AND api_key_id IS NULL;

-- A chat session must be owned by exactly one principal.
ALTER TABLE transcript_chat_sessions
    DROP CONSTRAINT IF EXISTS chat_session_owner_check;
ALTER TABLE transcript_chat_sessions
    ADD CONSTRAINT chat_session_owner_check
    CHECK (
        (user_id IS NOT NULL AND api_key_id IS NULL)
        OR
        (user_id IS NULL AND api_key_id IS NOT NULL)
    );

-- Drop legacy uniqueness and replace with ownership-specific partial unique indexes.
DROP INDEX IF EXISTS idx_chat_sessions_item_unique;

CREATE UNIQUE INDEX IF NOT EXISTS idx_chat_sessions_item_user_unique
    ON transcript_chat_sessions(item_type, item_id, user_id)
    WHERE user_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_chat_sessions_item_api_key_unique
    ON transcript_chat_sessions(item_type, item_id, api_key_id)
    WHERE api_key_id IS NOT NULL;
