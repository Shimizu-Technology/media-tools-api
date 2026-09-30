-- Older binaries treat every remaining row as active. Retain only the current
-- active set before removing the staging columns so rollback cannot resurrect
-- discarded or pending recovery codes.
DELETE FROM auth_recovery_codes WHERE NOT active;

DROP INDEX IF EXISTS auth_recovery_codes_user_active_idx;
ALTER TABLE auth_recovery_codes
    DROP COLUMN IF EXISTS active,
    DROP COLUMN IF EXISTS rotation_id;

DROP TABLE IF EXISTS auth_recovery_code_rotations;

CREATE INDEX auth_recovery_codes_user_id_idx
    ON auth_recovery_codes(user_id)
    WHERE consumed_at IS NULL;
