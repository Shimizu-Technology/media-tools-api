-- Migration 029: Claim existing production media for the original Shimizu owner.
--
-- Before Clerk-first auth, production was used by one owner via API keys. Those
-- rows are API-key-owned or unowned, so a Clerk sign-in for the owner would show
-- an empty user workspace. This idempotently creates the owner app user and
-- attaches existing unclaimed records to that user. Future records created by
-- other signed-in users keep their own user_id and are not affected.

INSERT INTO users (email, password_hash, name)
VALUES ('shimizutechnology@gmail.com', '', 'Shimizu Technology')
ON CONFLICT (email) DO UPDATE
SET name = CASE
    WHEN users.name = '' THEN EXCLUDED.name
    ELSE users.name
END;

-- Make existing developer/API keys visible from the owner's Developer page.
UPDATE api_keys
SET user_id = (SELECT id FROM users WHERE email = 'shimizutechnology@gmail.com')
WHERE user_id IS NULL;

-- Claim existing media library records.
UPDATE transcripts
SET user_id = (SELECT id FROM users WHERE email = 'shimizutechnology@gmail.com')
WHERE user_id IS NULL;

UPDATE audio_transcriptions
SET user_id = (SELECT id FROM users WHERE email = 'shimizutechnology@gmail.com')
WHERE user_id IS NULL;

UPDATE pdf_extractions
SET user_id = (SELECT id FROM users WHERE email = 'shimizutechnology@gmail.com')
WHERE user_id IS NULL;

-- Claim app-level organization records that existed before Clerk ownership.
UPDATE batches
SET user_id = (SELECT id FROM users WHERE email = 'shimizutechnology@gmail.com')
WHERE user_id IS NULL;

UPDATE collections
SET user_id = (SELECT id FROM users WHERE email = 'shimizutechnology@gmail.com')
WHERE user_id IS NULL;

UPDATE audio_upload_sessions
SET user_id = (SELECT id FROM users WHERE email = 'shimizutechnology@gmail.com')
WHERE user_id IS NULL;

-- User-owned chat session lookups intentionally require api_key_id IS NULL.
-- Convert legacy/API-key chat sessions to the owner user so prior chats follow
-- the item into the signed-in workspace.
UPDATE transcript_chat_sessions
SET user_id = (SELECT id FROM users WHERE email = 'shimizutechnology@gmail.com'),
    api_key_id = NULL
WHERE user_id IS NULL;
