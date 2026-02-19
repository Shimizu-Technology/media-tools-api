-- Revert: remove 'collection' from chat item types
ALTER TABLE transcript_chat_sessions
    DROP CONSTRAINT IF EXISTS chat_item_type_check;

ALTER TABLE transcript_chat_sessions
    ADD CONSTRAINT chat_item_type_check
    CHECK (item_type IN ('transcript', 'audio', 'pdf'));
