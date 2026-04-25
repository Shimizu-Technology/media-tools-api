-- Migration 026: Add ownership columns to batches for proper actor scoping.

ALTER TABLE batches
ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES users(id) ON DELETE SET NULL,
ADD COLUMN IF NOT EXISTS api_key_id UUID REFERENCES api_keys(id) ON DELETE SET NULL;

WITH batch_owners AS (
    SELECT DISTINCT ON (t.batch_id)
        t.batch_id,
        t.user_id,
        t.api_key_id
    FROM transcripts t
    WHERE t.batch_id IS NOT NULL
      AND (t.user_id IS NOT NULL OR t.api_key_id IS NOT NULL)
      AND NOT EXISTS (
          SELECT 1
          FROM transcripts t_conflict
          WHERE t_conflict.batch_id = t.batch_id
            AND (t_conflict.user_id IS NOT NULL OR t_conflict.api_key_id IS NOT NULL)
            AND (
                t_conflict.user_id IS DISTINCT FROM t.user_id
                OR t_conflict.api_key_id IS DISTINCT FROM t.api_key_id
            )
      )
    ORDER BY t.batch_id, t.created_at ASC, t.id ASC
)
UPDATE batches b
SET user_id = COALESCE(b.user_id, bo.user_id),
    api_key_id = COALESCE(b.api_key_id, bo.api_key_id)
FROM batch_owners bo
WHERE b.id = bo.batch_id;

CREATE INDEX IF NOT EXISTS idx_batches_user_id ON batches(user_id) WHERE user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_batches_api_key_id ON batches(api_key_id) WHERE api_key_id IS NOT NULL;
