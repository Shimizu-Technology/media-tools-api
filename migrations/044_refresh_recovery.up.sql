-- Link a consumed refresh credential to the client-supplied successor hash.
-- The raw credential is never stored, and only an exact old/successor pair
-- can recover an interrupted rotation.
ALTER TABLE auth_refresh_tokens ADD COLUMN successor_hash CHAR(64);
