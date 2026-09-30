CREATE TABLE auth_invitations (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email               VARCHAR(255) NOT NULL,
    name                VARCHAR(255) NOT NULL DEFAULT '',
    token_hash          CHAR(64) NOT NULL UNIQUE,
    expires_at          TIMESTAMPTZ NOT NULL,
    consumed_at         TIMESTAMPTZ,
    consumed_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX auth_invitations_email_idx ON auth_invitations(lower(email), created_at DESC);
CREATE INDEX auth_invitations_expiry_idx ON auth_invitations(expires_at) WHERE consumed_at IS NULL;

CREATE UNIQUE INDEX account_deletion_requests_app_user_id_idx
    ON account_deletion_requests(app_user_id);

ALTER TABLE account_deletion_requests
    ALTER COLUMN clerk_user_hash DROP NOT NULL;
