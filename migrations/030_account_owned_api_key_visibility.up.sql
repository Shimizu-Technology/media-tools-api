-- Make media created through a user-owned developer key visible in that
-- user's signed-in workspace. New writes populate both ownership columns; this
-- backfills rows created before that behavior existed.

UPDATE transcripts t
SET user_id = k.user_id
FROM api_keys k
WHERE t.api_key_id = k.id
  AND t.user_id IS NULL
  AND k.user_id IS NOT NULL;

UPDATE audio_transcriptions a
SET user_id = k.user_id
FROM api_keys k
WHERE a.api_key_id = k.id
  AND a.user_id IS NULL
  AND k.user_id IS NOT NULL;

UPDATE pdf_extractions p
SET user_id = k.user_id
FROM api_keys k
WHERE p.api_key_id = k.id
  AND p.user_id IS NULL
  AND k.user_id IS NOT NULL;

UPDATE batches b
SET user_id = k.user_id
FROM api_keys k
WHERE b.api_key_id = k.id
  AND b.user_id IS NULL
  AND k.user_id IS NOT NULL;

UPDATE collections c
SET user_id = k.user_id
FROM api_keys k
WHERE c.api_key_id = k.id
  AND c.user_id IS NULL
  AND k.user_id IS NOT NULL;

UPDATE audio_upload_sessions s
SET user_id = k.user_id
FROM api_keys k
WHERE s.api_key_id = k.id
  AND s.user_id IS NULL
  AND k.user_id IS NOT NULL;
