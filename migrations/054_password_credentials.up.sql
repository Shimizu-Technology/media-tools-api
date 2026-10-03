DO $$
BEGIN
    IF EXISTS (
        SELECT lower(normalize(btrim(email), NFC))
        FROM users
        GROUP BY lower(normalize(btrim(email), NFC))
        HAVING COUNT(*) > 1
    ) THEN
        RAISE EXCEPTION 'cannot add password credentials: duplicate normalized user emails exist';
    END IF;
END
$$;

-- Preserve the same canonical email identity for future Clerk and invited
-- accounts, not only for rows that happen to enroll a password.
CREATE UNIQUE INDEX users_email_normalized_unique
    ON users ((lower(normalize(btrim(email), NFC))));

CREATE TABLE auth_password_credentials (
    user_id                   UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    email_normalized          TEXT NOT NULL,
    password_hash             TEXT NOT NULL CHECK (length(password_hash) BETWEEN 20 AND 512),
    failed_attempts           INTEGER NOT NULL DEFAULT 0 CHECK (failed_attempts >= 0),
    failure_window_started_at TIMESTAMPTZ,
    locked_until              TIMESTAMPTZ,
    created_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX auth_password_credentials_email_unique
    ON auth_password_credentials(email_normalized);

CREATE INDEX auth_password_credentials_locked_until_idx
    ON auth_password_credentials(locked_until)
    WHERE locked_until IS NOT NULL;

-- Preserve any old development account without re-enabling its JWT routes.
-- Successful first-party login upgrades bcrypt to Argon2id atomically.
INSERT INTO auth_password_credentials (user_id, email_normalized, password_hash)
SELECT id, lower(normalize(btrim(email), NFC)), password_hash
FROM users
WHERE password_hash <> '';
