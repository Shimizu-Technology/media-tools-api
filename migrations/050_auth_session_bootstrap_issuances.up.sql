-- A native client saves its chosen refresh credential before asking Clerk to
-- bootstrap a first-party session. This link lets an exact retry recover the
-- same session when the successful HTTP response was lost. Only the
-- credential hash is stored; the bearer credential remains on the client.
CREATE TABLE auth_session_bootstrap_issuances (
    successor_hash CHAR(64) PRIMARY KEY,
    session_id UUID NOT NULL UNIQUE REFERENCES auth_sessions(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    client_type TEXT NOT NULL CHECK (client_type IN ('web', 'ios', 'android')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX auth_session_bootstrap_issuances_user_id_idx
    ON auth_session_bootstrap_issuances(user_id);
