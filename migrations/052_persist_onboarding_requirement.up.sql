-- The guided setup requirement is security state, not browser state. Keeping
-- it on the account prevents cookie deletion or expiry from bypassing the
-- required passkey and recovery-code setup.
ALTER TABLE users
    ADD COLUMN onboarding_required BOOLEAN NOT NULL DEFAULT FALSE;

