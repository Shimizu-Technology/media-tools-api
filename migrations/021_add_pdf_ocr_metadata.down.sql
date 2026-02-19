DROP INDEX IF EXISTS idx_pdf_extractions_extraction_method;

ALTER TABLE pdf_extractions
DROP COLUMN IF EXISTS ocr_confidence,
DROP COLUMN IF EXISTS ocr_text_pages,
DROP COLUMN IF EXISTS ocr_provider,
DROP COLUMN IF EXISTS extraction_method;
