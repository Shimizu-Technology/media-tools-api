CREATE TABLE auth_recovery_codes (
    code_hash CHAR(64) PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    consumed_at TIMESTAMPTZ
);
CREATE INDEX auth_recovery_codes_user_id_idx ON auth_recovery_codes(user_id) WHERE consumed_at IS NULL;
