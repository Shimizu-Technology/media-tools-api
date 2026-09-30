# First-party account recovery

Recovery codes are an emergency sign-in path for an account that has lost access
to its passkeys. They use the same application user ID and device sessions as
passkey sign-in. The routes are available only when `FIRST_PARTY_AUTH_ENABLED`
is on; the production flag must stay off until the client recovery screens are
ready and the existing account has saved its codes.

## Creating and replacing codes

Recovery-code setup uses two requests so losing a response or closing the app
cannot silently invalidate the only codes the user has saved.

1. From an existing first-party device session, call
   `POST /api/v1/auth/recovery/rotation/begin`. It returns
   `{"rotation_id":"...","codes":[...]}`. Save both the rotation ID and all ten
   codes together before showing them as ready to use. The server stores only
   hashes in an inactive pending set for 24 hours. Any old active codes remain
   valid.
2. After the codes are durably saved, call
   `POST /api/v1/auth/recovery/rotation/confirm` with the saved `rotation_id`.
   Confirmation atomically activates that set and invalidates the previous set.
   Retrying confirmation after a lost response is safe and returns the current
   remaining count while that exact set is still active.
3. If the client loses a begin response before saving it, begin again. The new
   begin discards the unknown pending hashes and returns a replacement pending
   set; it does not change the known active codes. If an unconfirmed rotation
   expires, discard its local journal and begin again.

`GET /api/v1/auth/recovery` reports only unused codes in the confirmed active
set. Pending codes never affect this count and cannot be redeemed.

## Signing in with a code

Before calling `POST /api/v1/auth/recovery/redeem`, an iOS or Android client
must generate a fresh 256-bit `mta_rt_` refresh token and save it durably in its
pending-auth journal. Send:

```json
{
  "code": "MTR-...",
  "client_type": "ios",
  "device_name": "Leon's iPhone",
  "next_refresh_token": "mta_rt_..."
}
```

The server consumes the code and creates the session with that exact refresh
token in one transaction. If the response is lost, retry the same code and the
same saved successor within 24 hours to recover the same session and receive a
fresh access token. A different, expired, revoked, or already rotated successor
gets the same generic rejection and does not create a session. Raw token
responses accept only `ios` and `android`; browser recovery must use a later
cookie-specific wrapper.

After recovery, enroll another passkey, rotate and confirm a fresh code set,
and offer revocation of any lost device from the sessions list.

## Staged rollout

1. Keep `FIRST_PARTY_AUTH_ENABLED` off in production while server migrations,
   native journaling, passkey setup, recovery screens, and session management
   are deployed and tested.
2. Enable the flag in a controlled owner test. Enroll a passkey, begin and
   confirm recovery codes, then verify normal redemption and a simulated lost
   response using the same saved successor.
3. Verify account switching, sign-out revocation, session expiry, replacement
   of an unconfirmed set, repeated confirmation, and recovery after an app
   restart before expanding access.
4. Add the cookie-only browser recovery flow before offering recovery on web.

Only SHA-256 hashes of 160-bit random codes are stored. Codes are bound to the
existing `users.id`, so recovery never links accounts by email address. The
public redeem route is rate limited by peer. All responses containing codes or
tokens use `Cache-Control: no-store`.
