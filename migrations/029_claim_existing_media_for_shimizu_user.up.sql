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
--
-- Multiple API keys may have opened separate chat sessions for the same item.
-- Migration 025 added a unique user-owned session per (item_type, item_id,
-- user_id), so we first collapse duplicate legacy sessions into one canonical
-- session per item. If an owner user session already exists, it wins; otherwise
-- the oldest legacy session wins. Messages from duplicate sessions are kept by
-- moving them onto the canonical session before deleting the duplicates.
WITH owner_user AS (
    SELECT id AS owner_id FROM users WHERE email = 'shimizutechnology@gmail.com'
), legacy_sessions AS (
    SELECT
        s.id,
        COALESCE(
            (
                SELECT owned.id
                FROM transcript_chat_sessions owned
                JOIN owner_user ou ON true
                WHERE owned.item_type = s.item_type
                  AND owned.item_id = s.item_id
                  AND owned.user_id = ou.owner_id
                  AND owned.api_key_id IS NULL
                ORDER BY owned.created_at ASC, owned.id ASC
                LIMIT 1
            ),
            FIRST_VALUE(s.id) OVER (
                PARTITION BY s.item_type, s.item_id
                ORDER BY s.created_at ASC, s.id ASC
            )
        ) AS keep_id
    FROM transcript_chat_sessions s
    WHERE s.user_id IS NULL
)
UPDATE transcript_chat_messages m
SET session_id = legacy_sessions.keep_id
FROM legacy_sessions
WHERE m.session_id = legacy_sessions.id
  AND legacy_sessions.id <> legacy_sessions.keep_id;

WITH owner_user AS (
    SELECT id AS owner_id FROM users WHERE email = 'shimizutechnology@gmail.com'
), legacy_sessions AS (
    SELECT
        s.id,
        COALESCE(
            (
                SELECT owned.id
                FROM transcript_chat_sessions owned
                JOIN owner_user ou ON true
                WHERE owned.item_type = s.item_type
                  AND owned.item_id = s.item_id
                  AND owned.user_id = ou.owner_id
                  AND owned.api_key_id IS NULL
                ORDER BY owned.created_at ASC, owned.id ASC
                LIMIT 1
            ),
            FIRST_VALUE(s.id) OVER (
                PARTITION BY s.item_type, s.item_id
                ORDER BY s.created_at ASC, s.id ASC
            )
        ) AS keep_id
    FROM transcript_chat_sessions s
    WHERE s.user_id IS NULL
)
DELETE FROM transcript_chat_sessions s
USING legacy_sessions
WHERE s.id = legacy_sessions.id
  AND legacy_sessions.id <> legacy_sessions.keep_id;

WITH owner_user AS (
    SELECT id AS owner_id FROM users WHERE email = 'shimizutechnology@gmail.com'
)
UPDATE transcript_chat_sessions s
SET user_id = owner_user.owner_id,
    api_key_id = NULL
FROM owner_user
WHERE s.user_id IS NULL;
