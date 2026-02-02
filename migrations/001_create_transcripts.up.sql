-- Migration 001: Create transcripts table
-- This is the core table for storing YouTube transcripts.
-- We use UUID primary keys (via gen_random_uuid()) for globally unique IDs.

-- Enable UUID generation if not already enabled
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS transcripts (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    youtube_url    TEXT NOT NULL,
    youtube_id     VARCHAR(20) NOT NULL,
    title          TEXT NOT NULL DEFAULT '',
    channel_name   TEXT NOT NULL DEFAULT '',
    duration       INTEGER NOT NULL DEFAULT 0,        -- Duration in seconds
    language       VARCHAR(10) NOT NULL DEFAULT 'en',
    transcript_text TEXT NOT NULL DEFAULT '',
    word_count     INTEGER NOT NULL DEFAULT 0,
    status         VARCHAR(20) NOT NULL DEFAULT 'pending',
    error_message  TEXT NOT NULL DEFAULT '',
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index on youtube_id for deduplication lookups
CREATE INDEX IF NOT EXISTS idx_transcripts_youtube_id ON transcripts(youtube_id);

-- Index on status for filtering
CREATE INDEX IF NOT EXISTS idx_transcripts_status ON transcripts(status);

-- Index on created_at for sorting
CREATE INDEX IF NOT EXISTS idx_transcripts_created_at ON transcripts(created_at DESC);
