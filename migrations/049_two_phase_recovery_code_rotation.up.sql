-- Recovery-code rotation is staged so a lost response never destroys the
-- only set the user has saved. Pending code hashes stay inactive until an
-- explicit confirmation atomically replaces the active set.
CREATE TABLE auth_recovery_code_rotations (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at   TIMESTAMPTZ NOT NULL,
    confirmed_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX auth_recovery_code_rotations_user_pending_idx
    ON auth_recovery_code_rotations(user_id, created_at DESC)
    WHERE confirmed_at IS NULL;

ALTER TABLE auth_recovery_codes
    ADD COLUMN rotation_id UUID REFERENCES auth_recovery_code_rotations(id) ON DELETE CASCADE,
    ADD COLUMN active BOOLEAN NOT NULL DEFAULT TRUE;

DROP INDEX auth_recovery_codes_user_id_idx;
CREATE INDEX auth_recovery_codes_user_active_idx
    ON auth_recovery_codes(user_id)
    WHERE active AND consumed_at IS NULL;
