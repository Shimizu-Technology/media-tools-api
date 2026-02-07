-- Migration 018: Allow chat sessions without transcript_id (audio/pdf)

ALTER TABLE transcript_chat_sessions
    ALTER COLUMN transcript_id DROP NOT NULL;
