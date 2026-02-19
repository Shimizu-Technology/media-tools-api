ALTER TABLE pdf_extractions
ADD COLUMN IF NOT EXISTS extraction_method TEXT NOT NULL DEFAULT 'text_layer',
ADD COLUMN IF NOT EXISTS ocr_provider TEXT NOT NULL DEFAULT '',
ADD COLUMN IF NOT EXISTS ocr_text_pages INTEGER NOT NULL DEFAULT 0,
ADD COLUMN IF NOT EXISTS ocr_confidence DOUBLE PRECISION NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_pdf_extractions_extraction_method
ON pdf_extractions (extraction_method);
