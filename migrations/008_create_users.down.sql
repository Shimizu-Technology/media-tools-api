DROP TABLE IF EXISTS workspace_items;
ALTER TABLE pdf_extractions DROP COLUMN IF EXISTS user_id;
ALTER TABLE audio_transcriptions DROP COLUMN IF EXISTS user_id;
ALTER TABLE transcripts DROP COLUMN IF EXISTS user_id;
ALTER TABLE api_keys DROP COLUMN IF EXISTS user_id;
DROP TABLE IF EXISTS users;
