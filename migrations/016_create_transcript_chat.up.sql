-- Migration 016: Transcript chat sessions and messages
-- Enables AI chat about a transcript with persistent conversation history.

CREATE TABLE IF NOT EXISTS transcript_chat_sessions (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transcript_id  UUID NOT NULL REFERENCES transcripts(id) ON DELETE CASCADE,
    api_key_id     UUID REFERENCES api_keys(id) ON DELETE SET NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (transcript_id, api_key_id)
);

CREATE INDEX IF NOT EXISTS idx_chat_sessions_transcript_id ON transcript_chat_sessions(transcript_id);
CREATE INDEX IF NOT EXISTS idx_chat_sessions_api_key_id ON transcript_chat_sessions(api_key_id);

CREATE TABLE IF NOT EXISTS transcript_chat_messages (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id  UUID NOT NULL REFERENCES transcript_chat_sessions(id) ON DELETE CASCADE,
    role        VARCHAR(20) NOT NULL CHECK (role IN ('user', 'assistant')),
    content     TEXT NOT NULL,
    model_used  TEXT NOT NULL DEFAULT '',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_chat_messages_session_id ON transcript_chat_messages(session_id);
CREATE INDEX IF NOT EXISTS idx_chat_messages_created_at ON transcript_chat_messages(created_at);
