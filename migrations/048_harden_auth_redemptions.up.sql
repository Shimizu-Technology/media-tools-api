-- Redemption credentials are generated and persisted by the client before it
-- sends the request. Keeping only the successor hash and resulting session ID
-- lets an exact retry recover a lost HTTP response without storing bearer
-- credentials in PostgreSQL.
ALTER TABLE auth_invitations
    ADD COLUMN successor_hash CHAR(64),
    ADD COLUMN consumed_session_id UUID REFERENCES auth_sessions(id) ON DELETE SET NULL;

ALTER TABLE auth_recovery_codes
    ADD COLUMN successor_hash CHAR(64),
    ADD COLUMN consumed_session_id UUID REFERENCES auth_sessions(id) ON DELETE SET NULL;

ALTER TABLE auth_passkey_ceremonies
    ADD COLUMN verified_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    ADD COLUMN issued_session_id UUID REFERENCES auth_sessions(id) ON DELETE SET NULL,
    ADD COLUMN successor_hash CHAR(64),
    ADD COLUMN completed_at TIMESTAMPTZ;
