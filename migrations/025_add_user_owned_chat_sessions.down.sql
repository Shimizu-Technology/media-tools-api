-- Rollback Migration 025: remove user-owned chat session support.

DROP INDEX IF EXISTS idx_chat_sessions_item_user_unique;
DROP INDEX IF EXISTS idx_chat_sessions_item_api_key_unique;
DROP INDEX IF EXISTS idx_chat_sessions_user_id;

ALTER TABLE transcript_chat_sessions
    DROP CONSTRAINT IF EXISTS chat_session_owner_check;

-- Restore the pre-existing uniqueness behavior.
CREATE UNIQUE INDEX IF NOT EXISTS idx_chat_sessions_item_unique
    ON transcript_chat_sessions(item_type, item_id, api_key_id);

ALTER TABLE transcript_chat_sessions
    DROP COLUMN IF EXISTS user_id;
