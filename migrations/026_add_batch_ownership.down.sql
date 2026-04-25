DROP INDEX IF EXISTS idx_batches_api_key_id;
DROP INDEX IF EXISTS idx_batches_user_id;

ALTER TABLE batches
DROP COLUMN IF EXISTS api_key_id,
DROP COLUMN IF EXISTS user_id;
