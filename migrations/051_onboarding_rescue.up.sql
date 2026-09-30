-- New invitations replace older unused links for the same email. Keeping a
-- revocation timestamp preserves the audit trail without allowing two active
-- links to race account creation.
ALTER TABLE auth_invitations
    ADD COLUMN revoked_at TIMESTAMPTZ;

CREATE INDEX auth_invitations_active_email_idx
    ON auth_invitations(lower(email), created_at DESC)
    WHERE consumed_at IS NULL AND revoked_at IS NULL;

-- An onboarding rescue link targets the immutable application user ID. It is
-- available only while that account has no passkey or usable recovery code.
-- The client chooses and saves the refresh credential before redemption so an
-- exact retry can recover a lost successful response.
CREATE TABLE auth_onboarding_reissues (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash          CHAR(64) NOT NULL UNIQUE,
    expires_at          TIMESTAMPTZ NOT NULL,
    consumed_at         TIMESTAMPTZ,
    consumed_session_id UUID REFERENCES auth_sessions(id) ON DELETE SET NULL,
    successor_hash      CHAR(64),
    revoked_at          TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX auth_onboarding_reissues_user_idx
    ON auth_onboarding_reissues(user_id, created_at DESC);

CREATE INDEX auth_onboarding_reissues_expiry_idx
    ON auth_onboarding_reissues(expires_at)
    WHERE consumed_at IS NULL AND revoked_at IS NULL;
