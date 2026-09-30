ALTER TABLE auth_passkey_ceremonies
    DROP COLUMN IF EXISTS completed_at,
    DROP COLUMN IF EXISTS successor_hash,
    DROP COLUMN IF EXISTS issued_session_id,
    DROP COLUMN IF EXISTS verified_user_id;

ALTER TABLE auth_recovery_codes
    DROP COLUMN IF EXISTS consumed_session_id,
    DROP COLUMN IF EXISTS successor_hash;

ALTER TABLE auth_invitations
    DROP COLUMN IF EXISTS consumed_session_id,
    DROP COLUMN IF EXISTS successor_hash;
