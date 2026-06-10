-- No-op rollback.
--
-- api_keys.user_id is part of the baseline user schema from migration 008.
-- Migration 028 only repairs drifted databases and should not drop a shared
-- ownership column or index that earlier migrations and application code use.
SELECT 1;
