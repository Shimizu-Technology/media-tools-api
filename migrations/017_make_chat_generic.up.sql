-- Migration 017: Make chat sessions generic across content types

ALTER TABLE transcript_chat_sessions
    ADD COLUMN IF NOT EXISTS item_type VARCHAR(20) NOT NULL DEFAULT 'transcript',
    ADD COLUMN IF NOT EXISTS item_id UUID;

UPDATE transcript_chat_sessions
SET item_id = transcript_id
WHERE item_id IS NULL;

ALTER TABLE transcript_chat_sessions
    ALTER COLUMN item_id SET NOT NULL;

ALTER TABLE transcript_chat_sessions
    ADD CONSTRAINT chat_item_type_check
    CHECK (item_type IN ('transcript', 'audio', 'pdf'));

CREATE UNIQUE INDEX IF NOT EXISTS idx_chat_sessions_item_unique
    ON transcript_chat_sessions(item_type, item_id, api_key_id);

CREATE INDEX IF NOT EXISTS idx_chat_sessions_item_id
    ON transcript_chat_sessions(item_id);
