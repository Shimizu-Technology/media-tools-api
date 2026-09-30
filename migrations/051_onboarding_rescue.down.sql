DROP TABLE IF EXISTS auth_onboarding_reissues;
DROP INDEX IF EXISTS auth_invitations_active_email_idx;
ALTER TABLE auth_invitations DROP COLUMN IF EXISTS revoked_at;
