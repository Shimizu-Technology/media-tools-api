-- Rollback migration 018: require transcript_id again

ALTER TABLE transcript_chat_sessions
    ALTER COLUMN transcript_id SET NOT NULL;
