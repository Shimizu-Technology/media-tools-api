-- Add clerk_id column to users table for Clerk authentication.
-- Existing users (email/password) keep working; clerk_id is nullable for backward compat.
ALTER TABLE users ADD COLUMN IF NOT EXISTS clerk_id VARCHAR(255);
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_clerk_id ON users (clerk_id) WHERE clerk_id IS NOT NULL;
