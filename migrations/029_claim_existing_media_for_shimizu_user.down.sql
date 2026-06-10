-- No-op rollback.
--
-- This is an ownership/data backfill for the original production user. Rolling
-- it back by nulling user_id columns would hide production data from the owner,
-- so rollback is intentionally non-destructive.
SELECT 1;
