DELETE FROM account_deletion_requests WHERE clerk_user_hash IS NULL;

ALTER TABLE account_deletion_requests
    ALTER COLUMN clerk_user_hash SET NOT NULL;

DROP INDEX IF EXISTS account_deletion_requests_app_user_id_idx;
DROP TABLE IF EXISTS auth_invitations;
