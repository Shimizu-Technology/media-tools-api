-- Migration 024: Allow 'collection' as a chat session item_type

ALTER TABLE transcript_chat_sessions
    DROP CONSTRAINT IF EXISTS chat_item_type_check;

ALTER TABLE transcript_chat_sessions
    ADD CONSTRAINT chat_item_type_check
    CHECK (item_type IN ('transcript', 'audio', 'pdf', 'collection'));
