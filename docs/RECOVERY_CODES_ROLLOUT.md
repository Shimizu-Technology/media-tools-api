# First-party account recovery

Recovery codes are an emergency sign-in path for an account that has lost access
to its passkeys. They use the same application user ID and device sessions as
passkey sign-in. The routes are available only when `FIRST_PARTY_AUTH_ENABLED`
is on; the production flag must stay off until the client recovery screens are
ready and the existing account has saved its codes.

1. From an existing first-party device session, `POST /api/v1/auth/recovery`
   returns ten codes. Show and save them once. A second call invalidates every
   previous code. `GET /api/v1/auth/recovery` reports only the remaining count.
2. On the sign-in screen, `POST /api/v1/auth/recovery/redeem` accepts
   `{"code":"MTR-...","client_type":"ios","device_name":"..."}` and returns a
   new access/refresh pair. Each code can be used once. A successful request
   consumes the code and creates the session in a single transaction.
3. After signing in with a code, enroll another passkey and replace the codes.
   Offer revocation of any lost device from the sessions list.

Only SHA-256 hashes of 160-bit random codes are stored. Codes are bound to the
existing `users.id`, so recovery never links accounts by email address. The
public redeem route is rate limited by peer. All responses containing codes or
tokens use `Cache-Control: no-store`.
