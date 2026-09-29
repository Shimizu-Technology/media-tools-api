-- Passkeys belong to the existing application user, never to an email address.
CREATE TABLE auth_passkey_credentials (
    credential_id BYTEA PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    credential JSONB NOT NULL,
    revision BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_used_at TIMESTAMPTZ
);
CREATE INDEX auth_passkey_credentials_user_id_idx ON auth_passkey_credentials(user_id);

-- Challenges are kept server-side, bound to the registration session when
-- appropriate, and consumed once before verification to prevent replay.
CREATE TABLE auth_passkey_ceremonies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kind TEXT NOT NULL CHECK (kind IN ('register', 'login')),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    auth_binding TEXT NOT NULL DEFAULT '',
    session_data JSONB NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT auth_passkey_ceremony_scope CHECK (
        (kind = 'register' AND user_id IS NOT NULL AND auth_binding <> '') OR
        (kind = 'login' AND user_id IS NULL AND auth_binding = '')
    )
);
CREATE INDEX auth_passkey_ceremonies_expiry_idx ON auth_passkey_ceremonies(expires_at);
