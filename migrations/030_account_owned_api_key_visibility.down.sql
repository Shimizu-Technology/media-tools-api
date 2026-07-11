-- Irreversible data backfill. Removing user_id values on rollback could detach
-- records created legitimately after this migration, so the down migration is
-- intentionally a no-op.
SELECT 1;
