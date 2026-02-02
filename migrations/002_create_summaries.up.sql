-- Migration 002: Create summaries table
-- Stores AI-generated summaries linked to transcripts.
-- key_points uses JSONB for flexible structured data.

CREATE TABLE IF NOT EXISTS summaries (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transcript_id  UUID NOT NULL REFERENCES transcripts(id) ON DELETE CASCADE,
    model_used     VARCHAR(100) NOT NULL,
    prompt_used    TEXT NOT NULL DEFAULT '',
    summary_text   TEXT NOT NULL DEFAULT '',
    key_points     JSONB DEFAULT '[]'::jsonb,         -- Array of key points as JSON
    length         VARCHAR(20) NOT NULL DEFAULT 'medium',  -- short, medium, detailed
    style          VARCHAR(20) NOT NULL DEFAULT 'bullet',  -- bullet, narrative, academic
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index for looking up summaries by transcript
CREATE INDEX IF NOT EXISTS idx_summaries_transcript_id ON summaries(transcript_id);
