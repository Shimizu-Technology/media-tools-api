-- Migration 026: Add ownership columns to batches for proper actor scoping.

ALTER TABLE batches
ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES users(id) ON DELETE SET NULL,
ADD COLUMN IF NOT EXISTS api_key_id UUID REFERENCES api_keys(id) ON DELETE SET NULL;

WITH batch_owners AS (
    SELECT
        batch_id,
        MAX(user_id) AS user_id,
        MAX(api_key_id) AS api_key_id
    FROM transcripts
    WHERE batch_id IS NOT NULL
    GROUP BY batch_id
)
UPDATE batches b
SET user_id = COALESCE(b.user_id, bo.user_id),
    api_key_id = COALESCE(b.api_key_id, bo.api_key_id)
FROM batch_owners bo
WHERE b.id = bo.batch_id;

CREATE INDEX IF NOT EXISTS idx_batches_user_id ON batches(user_id) WHERE user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_batches_api_key_id ON batches(api_key_id) WHERE api_key_id IS NOT NULL;
