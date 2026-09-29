# Passkey API contract

This is the server ceremony contract for the staged first-party authentication
rollout. `FIRST_PARTY_AUTH_ENABLED=false` keeps the routes unavailable. The
production relying-party ID is `media.shimizu-technology.com`, with web origin
`https://media.shimizu-technology.com`. Changing that ID strands registered
credentials. iOS uses the same domain through its Associated Domains entitlement.
An Android origin needs separately verified production signing metadata before
Android passkeys can be enabled.

## Enroll an existing account

1. Sign in through Clerk or a first-party device session. Call
   `POST /api/v1/auth/passkeys/register/begin` with its Bearer token and an
   empty JSON object. A legacy JWT or API key cannot enroll a passkey.
2. The response is `{"ceremony_id":"<uuid>","options":{...}}`. Pass `options`
   to the platform's WebAuthn registration API. Its binary fields are unpadded
   base64url strings and must be decoded to bytes for browser or native APIs.
3. Call `POST /api/v1/auth/passkeys/register/finish` with the **same** Bearer
   session and `{"ceremony_id":"<uuid>","credential":{...}}`. The credential
   is the platform's registration response in WebAuthn JSON form. Encode its
   binary fields as unpadded base64url, including `rawId`, `clientDataJSON`,
   and `attestationObject`. Include `id` and `type: "public-key"`.
4. A successful response is HTTP 201 with `credential_id` in unpadded base64url.

The challenge expires after five minutes. It belongs to that account and
session. A finish attempt consumes it, including an invalid attempt; begin a
new ceremony before retrying. The authenticator must create a discoverable
credential and verify the user.

## Sign in

1. Call `POST /api/v1/auth/passkeys/login/begin` with `{}`. No prior
   authentication is required. Its response has the same `ceremony_id` and
   `options` envelope. Invoke a discoverable credential assertion with the
   returned options.
2. Call `POST /api/v1/auth/passkeys/login/finish` with:

   ```json
   {
     "ceremony_id": "<uuid>",
     "credential": {"id": "<base64url>", "rawId": "<base64url>", "type": "public-key", "response": {}},
     "client_type": "ios",
     "device_name": "Leon's iPhone"
   }
   ```

   The assertion `response` must contain base64url `clientDataJSON`,
   `authenticatorData`, and `signature`, plus `userHandle` when supplied by
   the platform. `client_type` is `web`, `ios`, or `android`; `device_name` is
   optional and at most 80 characters. The server verifies challenge, RP ID,
   origin, user verification, account ownership, and signature.
3. HTTP 201 returns the existing first-party token pair and session metadata.
   Store the refresh credential in the platform's secure storage and use the
   existing `/auth/session/refresh` flow. Sign-out revokes that device session;
   the passkey itself remains enrolled.

Browser clients can use `PublicKeyCredential.toJSON()` where available. Native
clients construct the same credential JSON from the platform response's raw
byte properties; they must not send standard padded base64 or UTF-8 text in
place of bytes. All ceremony and credential responses use `Cache-Control:
no-store`.

## Rollout dependencies

- Registration currently accepts Clerk Bearer sessions and first-party Bearer
  device sessions. The staged browser cookie work must add a session-bound
  registration path with origin and CSRF checks before the web app enrolls
  passkeys through cookies. Do not put refresh credentials in JavaScript storage.
- This server slice does not turn on first-party auth, migrate existing clients,
  establish account recovery, or provide new-user onboarding. Those flows need
  completion before Clerk can be removed.
- No Android passkey origin is allowed until the production signing certificate
  and Digital Asset Links association are verified.
