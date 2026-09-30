# Passkey authentication contract

Passkeys are the primary durable sign-in method for Media Tools. Routes remain
unavailable while `FIRST_PARTY_AUTH_ENABLED=false`. The relying-party ID is
`media.shimizu-technology.com` and the web origin is
`https://media.shimizu-technology.com`. Changing the RP ID strands existing
credentials. iOS uses the same domain through Associated Domains. Android must
not be enabled until its production signing identity and Digital Asset Links
association are verified.

## Enroll an existing account

An enrollment requires a first-party device session or a verified Clerk bridge
session. Legacy JWTs and API keys cannot enroll passkeys.

1. Read `GET /api/v1/auth/passkeys` and save the current `count`. The web app
   authenticates with its access cookie; native clients send a Bearer token.
2. Call `POST /api/v1/auth/passkeys/register/begin` and pass the returned inner
   `options` object to the platform WebAuthn registration API.
3. Call `POST /api/v1/auth/passkeys/register/finish` with the same session and
   `{"ceremony_id":"<uuid>","credential":{...}}`.
4. After an ambiguous network failure, read the count again. An increase is the
   durable receipt that registration committed and prevents a duplicate prompt.

The challenge expires after five minutes and belongs to the exact account and
session. Every finish attempt consumes it, including an invalid attempt. Binary
WebAuthn fields use unpadded base64url. Browsers should use
`PublicKeyCredential.parseCreationOptionsFromJSON()` and `credential.toJSON()`
when available; the checked fallback performs only the required binary-field
conversions.

## Native sign-in

Native clients use the public `/api/v1/auth/passkeys/login/begin` and `/finish`
routes. Before finish, generate and persist a canonical `mta_rt_` successor in
secure storage with the ceremony ID and credential JSON. The finish body is:

```json
{
  "ceremony_id": "<uuid>",
  "credential": {"id": "<base64url>", "rawId": "<base64url>", "type": "public-key", "response": {}},
  "client_type": "ios",
  "device_name": "Leon's iPhone",
  "next_refresh_token": "mta_rt_<saved-random-value>"
}
```

Raw token responses accept `ios` and `android`; `client_type:web` is rejected.
HTTP 201 returns the token pair. If the response is lost, retry the same ceremony
and exact saved successor without opening another platform prompt. The server
recovers the same session and mints only a fresh short-lived access token. A
wrong successor, expired recovery window, revoked session, or different account
does not reveal the issuance.

## Browser sign-in

The web app never calls a raw token-returning finish route. It uses:

1. `POST /api/v1/auth/web/session/passkeys/login/begin` with the exact allowed
   `Origin`. The response installs a host-only HttpOnly pending successor and a
   readable CSRF cookie, then returns the ceremony and options.
2. The browser journals only `ceremony_id`, gets the assertion, and calls
   `POST /api/v1/auth/web/session/passkeys/login/finish` with the CSRF header.
3. Finish writes access and refresh credentials only to host-only HttpOnly,
   `SameSite=Strict` cookies. The JSON body contains user and expiry metadata,
   never a bearer token.
4. If the response is lost or the tab reloads, the browser retries the journaled
   ceremony without another assertion. The pending HttpOnly successor recovers
   the same server session. The journal is cleared only after status confirms
   the installed session.

Passkey enrollment in Settings uses the same cookie-authenticated registration
routes with exact-Origin CSRF checks. Clerk remains an optional migration bridge
for an existing account; browser passkey restore and sign-in work without Clerk
configuration or a Clerk session.

## Remaining rollout dependency

Recovery codes and invite-only onboarding must be verified before Clerk is
removed. No Android passkey origin is allowed until production app association
is verified. All ceremony and credential responses use `Cache-Control: no-store`.
