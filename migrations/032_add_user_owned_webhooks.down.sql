DELETE FROM webhooks WHERE user_id IS NOT NULL;
DROP INDEX IF EXISTS idx_webhooks_user_id;

ALTER TABLE webhooks
    DROP CONSTRAINT IF EXISTS webhook_owner_check,
    DROP COLUMN IF EXISTS user_id;
ALTER TABLE webhooks
    ALTER COLUMN api_key_id SET NOT NULL;
