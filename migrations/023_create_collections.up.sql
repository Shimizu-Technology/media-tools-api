-- Collections: user-created groups for organizing transcripts, audio, and PDFs.
CREATE TABLE IF NOT EXISTS collections (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(255) NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    api_key_id UUID REFERENCES api_keys(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS collection_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    collection_id UUID NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
    item_type VARCHAR(20) NOT NULL CHECK (item_type IN ('transcript', 'audio', 'pdf')),
    item_id UUID NOT NULL,
    position INT NOT NULL DEFAULT 0,
    added_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(collection_id, item_type, item_id)
);

CREATE INDEX idx_collections_user_id ON collections(user_id);
CREATE INDEX idx_collections_api_key_id ON collections(api_key_id);
CREATE INDEX idx_collection_items_collection_id ON collection_items(collection_id);
CREATE INDEX idx_collection_items_item ON collection_items(item_type, item_id);
