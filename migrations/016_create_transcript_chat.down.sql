-- Rollback migration 016: drop transcript chat tables

DROP TABLE IF EXISTS transcript_chat_messages;
DROP TABLE IF EXISTS transcript_chat_sessions;
