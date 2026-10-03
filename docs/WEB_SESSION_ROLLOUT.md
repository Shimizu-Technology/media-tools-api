# Browser session rollout

Media Tools web auth uses first-party access and refresh cookies. A passkey can
restore or create that session without Clerk. Clerk is an optional migration
bridge that links a verified existing Clerk subject to the same stable
`users.id`; it is not required after a user has enrolled a password or passkey
and saved recovery codes.

## Security contract

- Access, refresh, and pending-successor cookies are host-only, HttpOnly,
  `SameSite=Strict`, and `Secure` in release mode. JavaScript never receives an
  access or refresh token.
- Mutations require an exact configured `Origin` and a constant-time match
  between the readable CSRF cookie and `X-CSRF-Token`. A signed-out begin route
  uses exact Origin to issue the initial CSRF secret.
- Refresh, passkey finish, and Clerk bootstrap persist a pending successor
  before committing server state. Exact retries recover the same session after
  a lost response rather than creating an orphan. The passkey ceremony ID is
  the only passkey login state journaled in web storage.
- Recovery sign-in uses a separate pending successor. The submitted recovery
  code stays only in component memory. Redemption, creation of the replacement
  session, and revocation of any prior browser session commit atomically. A
  stale successor is cleared and prepared once before retrying the same unused
  code; ordinary wrong codes leave the prepared successor usable.
- When Clerk is active, its subject must exactly match the restored cookie
  user's linked Clerk ID. A different or unlinked cookie account is revoked
  before the Clerk account can bootstrap. A revocation failure exposes neither
  workspace.
- AI-processing consent moves from the linked Clerk subject key to stable
  `users.id` only after the cookie session confirms that mapping. The old grant
  is removed only after the stable grant is written successfully.

## Deployment order

1. Keep the already-live `FIRST_PARTY_AUTH_ENABLED=true` and
   `CLERK_MIGRATION_ONLY=true`. Deploy migration 054 and the password API with
   `FIRST_PARTY_PASSWORD_AUTH_ENABLED=false` and
   `WEB_COOKIE_AUTH_ENABLED=false`.
2. Configure the exact canonical `CORS_ORIGIN` as
   `https://media.shimizu-technology.com`. Add a preview origin only when it is
   intentionally trusted for auth. Keep `WEB_COOKIE_SECURE=true` in production.
3. Verify Netlify sends `/api/*` to the Render API through the same-origin proxy
   and that the old Netlify hostname redirects to the canonical domain.
4. Confirm the existing owner has an exact Clerk identity in
   `auth_identities` (or an exact legacy `users.clerk_id`). Verify the owner can
   still authenticate and an
   unknown Clerk subject receives a generic 401 without creating a user. In
   release mode the server refuses to start with Clerk plus first-party auth
   unless this guard is enabled.
5. Enable only `FIRST_PARTY_PASSWORD_AUTH_ENABLED` for the build 13 iOS
   rollout. Verify readiness, password enrollment, sign-in, response-loss
   retry, replacement revocation, passkey/recovery fallback, and sign-out on
   the physical iPhone. Keep `WEB_COOKIE_AUTH_ENABLED=false`.
6. For the later browser rollout, enable `WEB_COOKIE_AUTH_ENABLED`, then build
   the frontend with `VITE_WEB_COOKIE_AUTH_ENABLED=true` and no
   `VITE_API_URL`. `VITE_CLERK_PUBLISHABLE_KEY` may remain during migration, but
   also test a build without it: passkey restore, passkey sign-in, Settings
   enrollment, recovery-code sign-in and rotation, account deletion, and
   sign-out must still work.
7. On the existing owner account, confirm the same stable user and media appear,
   create a password or enroll a passkey, save recovery codes, sign out, sign in with the first-party method,
   reload after access expiry, simulate a lost finish response, and verify the
   previous Clerk sign-in can still bridge only the same account.

The browser session remains valid for up to 365 days of inactivity. Access
credentials last 15 minutes and renew through the prepared-successor flow.
Sign-out revokes the current device session before clearing browser state.

## Rollback

Disable `VITE_WEB_COOKIE_AUTH_ENABLED` first so new browser traffic stops using
cookie auth. Then disable `WEB_COOKIE_AUTH_ENABLED` after in-flight traffic has
drained. Keep `FIRST_PARTY_AUTH_ENABLED` while native clients use first-party
sessions. Do not remove migrations or delete session rows during rollback.
Clerk remains the temporary fallback until password or passkey plus recovery sign-in have
been verified on the owner account and future-user onboarding is available.
If first-party auth must be rolled back temporarily, leave
`CLERK_MIGRATION_ONLY=true`; reopening Clerk account creation would bypass
invite-only onboarding. Disable the migration guard only as a deliberate policy
change after reviewing that impact.

## Clerk retirement

After the owner has enrolled a password or passkey and confirmed a recovery-code set, use
`GET /api/v1/auth/clerk-detachment` from a first-party session to verify the
factor counts. `POST /api/v1/auth/clerk-detachment` then removes only the Clerk
link; the stable user, media, API keys, and device sessions remain. The detach
request is idempotent and refuses a linked account that lacks a password or
passkey plus an unused recovery code.

On iOS, Settings reads this readiness from the current first-party device
session and shows the disconnect action only when both requirements are ready. The
client changes its stored session from Clerk-bootstrapped to first-party only
after the server reports `linked:false`; it keeps the same session, stable user
ID, recordings, and upload ownership. If the detach response or local Keychain
write is interrupted, the next status read repairs the local state before the
old Clerk session is cleared. Never revoke the first-party device session as
part of provider detachment.

Keep `LEGACY_AUTH_ENABLED=false` in production. That setting controls both the
old email/password routes and acceptance of old HS256 bearer tokens, including
when no Clerk JWKS is configured. After detachment, account deletion uses the
first-party session and does not depend on Clerk configuration.
