-- Migration 028: Ensure API keys can be owned by Clerk/local users.
--
-- Migration 008 already adds api_keys.user_id for normal databases. This
-- idempotent repair migration keeps newer user-scoped API-key code safe on
-- databases that were created manually or drifted before that column existed.

ALTER TABLE api_keys
ADD COLUMN IF NOT EXISTS user_id UUID;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY(c.conkey)
        WHERE c.conrelid = 'api_keys'::regclass
          AND c.confrelid = 'users'::regclass
          AND c.contype = 'f'
          AND a.attname = 'user_id'
    ) THEN
        ALTER TABLE api_keys
        ADD CONSTRAINT api_keys_user_id_fkey
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_api_keys_user_id ON api_keys(user_id) WHERE user_id IS NOT NULL;
