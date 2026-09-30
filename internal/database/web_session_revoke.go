package database

import (
	"context"
	"fmt"
)

// RevokeFirstPartySessionByRefreshToken invalidates only the session that owns
// this credential. Logout works even after the short access token has expired.
func (db *DB) RevokeFirstPartySessionByRefreshToken(ctx context.Context, credential string) error {
	hash, ok := authTokenHash(credential, "mta_rt_")
	if !ok {
		return ErrSessionInvalid
	}
	_, err := db.ExecContext(ctx, `
		UPDATE auth_sessions s SET revoked_at = COALESCE(s.revoked_at, NOW())
		FROM auth_refresh_tokens t
		WHERE t.session_id = s.id AND t.token_hash = $1
		  AND t.consumed_at IS NULL AND t.expires_at > NOW()
		  AND s.inactive_expires_at > NOW()`, hash)
	if err != nil {
		return fmt.Errorf("revoke web session: %w", err)
	}
	return nil
}
