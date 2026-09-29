-- First-party device sessions are additive while Clerk remains available.
-- The app's existing users.id stays the ownership key for every media row.
CREATE TABLE auth_identities (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider TEXT NOT NULL,
    subject TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (provider, subject)
);
CREATE INDEX auth_identities_user_id_idx ON auth_identities(user_id);

CREATE TABLE auth_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    client_type TEXT NOT NULL CHECK (client_type IN ('web', 'ios', 'android')),
    device_name TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_used_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    inactive_expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ
);
CREATE INDEX auth_sessions_user_id_idx ON auth_sessions(user_id, created_at DESC);

CREATE TABLE auth_access_tokens (
    token_hash CHAR(64) PRIMARY KEY,
    session_id UUID NOT NULL REFERENCES auth_sessions(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX auth_access_tokens_session_id_idx ON auth_access_tokens(session_id);

-- Retain consumed refresh hashes until their expiry to detect replay.
CREATE TABLE auth_refresh_tokens (
    token_hash CHAR(64) PRIMARY KEY,
    session_id UUID NOT NULL REFERENCES auth_sessions(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ
);
CREATE INDEX auth_refresh_tokens_session_id_idx ON auth_refresh_tokens(session_id);

INSERT INTO auth_identities (user_id, provider, subject)
SELECT id, 'clerk', clerk_id FROM users WHERE clerk_id IS NOT NULL;
