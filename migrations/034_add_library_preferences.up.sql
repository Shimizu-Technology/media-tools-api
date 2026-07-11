CREATE TABLE IF NOT EXISTS media_item_preferences (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    api_key_id UUID REFERENCES api_keys(id) ON DELETE CASCADE,
    item_type VARCHAR(20) NOT NULL CHECK (item_type IN ('youtube', 'audio', 'pdf')),
    item_id UUID NOT NULL,
    favorite BOOLEAN NOT NULL DEFAULT FALSE,
    archived BOOLEAN NOT NULL DEFAULT FALSE,
    tags JSONB NOT NULL DEFAULT '[]',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT media_item_preferences_one_owner CHECK ((user_id IS NOT NULL) <> (api_key_id IS NOT NULL))
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_media_item_preferences_user_item
    ON media_item_preferences(user_id, item_type, item_id)
    WHERE user_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_media_item_preferences_key_item
    ON media_item_preferences(api_key_id, item_type, item_id)
    WHERE api_key_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_media_item_preferences_user_filters
    ON media_item_preferences(user_id, archived, favorite);

CREATE INDEX IF NOT EXISTS idx_media_item_preferences_tags ON media_item_preferences USING GIN(tags);
