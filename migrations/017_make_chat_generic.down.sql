-- Rollback migration 017: remove generic chat columns

DROP INDEX IF EXISTS idx_chat_sessions_item_unique;
DROP INDEX IF EXISTS idx_chat_sessions_item_id;
ALTER TABLE transcript_chat_sessions DROP CONSTRAINT IF EXISTS chat_item_type_check;
ALTER TABLE transcript_chat_sessions DROP COLUMN IF EXISTS item_type;
ALTER TABLE transcript_chat_sessions DROP COLUMN IF EXISTS item_id;
