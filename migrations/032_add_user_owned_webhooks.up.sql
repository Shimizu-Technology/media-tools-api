-- Signed-in users can manage webhooks without copying a raw API key into
-- browser storage. API-key-owned webhooks remain fully backward compatible.

ALTER TABLE webhooks
    ALTER COLUMN api_key_id DROP NOT NULL,
    ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES users(id) ON DELETE CASCADE;

ALTER TABLE webhooks
    DROP CONSTRAINT IF EXISTS webhook_owner_check;
ALTER TABLE webhooks
    ADD CONSTRAINT webhook_owner_check
    CHECK (
        (user_id IS NOT NULL AND api_key_id IS NULL)
        OR
        (user_id IS NULL AND api_key_id IS NOT NULL)
    );

CREATE INDEX IF NOT EXISTS idx_webhooks_user_id
    ON webhooks(user_id) WHERE user_id IS NOT NULL;
