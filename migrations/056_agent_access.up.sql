-- Migration 055: Scoped agent keys and agent activity.
--
-- Scopes live in their own table instead of a new api_keys column. The
-- currently deployed server loads api_keys with SELECT * into a fixed struct,
-- so adding a column there would break it until the new build is live. A key
-- with no rows here is a classic key and keeps its exact-key read behavior.
CREATE TABLE IF NOT EXISTS api_key_scopes (
    api_key_id UUID NOT NULL REFERENCES api_keys(id) ON DELETE CASCADE,
    scope      VARCHAR(32) NOT NULL
        CHECK (scope IN ('library:read', 'library:write', 'library:delete', 'capture:upload')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (api_key_id, scope)
);

-- One row per mutating (or denied) scoped-key request. It records who did what
-- to which item, never the request or response body, query string, or any
-- title or transcript text. api_key_name is copied so the log stays readable
-- after a key is renamed or removed.
CREATE TABLE IF NOT EXISTS agent_activity (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    api_key_id   UUID REFERENCES api_keys(id) ON DELETE SET NULL,
    api_key_name VARCHAR(200) NOT NULL,
    method       VARCHAR(10) NOT NULL,
    route        VARCHAR(200) NOT NULL,
    item_type    VARCHAR(20) NOT NULL DEFAULT '',
    item_id      VARCHAR(64) NOT NULL DEFAULT '',
    status_code  INTEGER NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_agent_activity_user_created
    ON agent_activity(user_id, created_at DESC);
