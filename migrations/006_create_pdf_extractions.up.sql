-- Migration 006: Create pdf_extractions table (MTA-17)
-- Stores PDF text extraction results.

CREATE TABLE IF NOT EXISTS pdf_extractions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    filename        VARCHAR(255) NOT NULL,                      -- Stored filename (UUID-based)
    original_name   VARCHAR(500) NOT NULL,                      -- User's original filename
    page_count      INTEGER NOT NULL DEFAULT 0,                 -- Number of pages in the PDF
    text_content    TEXT NOT NULL DEFAULT '',                    -- Extracted text content
    word_count      INTEGER NOT NULL DEFAULT 0,                 -- Word count of extracted text
    status          VARCHAR(20) NOT NULL DEFAULT 'completed',   -- completed or failed
    error_message   TEXT NOT NULL DEFAULT '',                    -- Error details if failed
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index on created_at for sorting
CREATE INDEX IF NOT EXISTS idx_pdf_extractions_created_at ON pdf_extractions(created_at DESC);
