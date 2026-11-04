# Email/password auth API

Workstream D contract for web (E), iOS (F), and Android (G). Existing passkey,
Clerk bridge, recovery and `/auth/session/*` contracts remain available. All paths
below start with `/api/v1`. Errors retain `{"error","message","code"}`; `code`
is the HTTP status, and `error` is the stable machine-readable identifier.

## Availability and rollout

`GET /health` and `/api/v1/health` expose `signup_enabled`,
`password_auth_enabled` and `auth_capabilities` (`email_codes`, `password_reset`,
`optional_passkeys`). Health remains process-only, without a database query.

- `FIRST_PARTY_AUTH_ENABLED` and `FIRST_PARTY_PASSWORD_AUTH_ENABLED` gate password
  and email-proof routes. `PUBLIC_SIGNUP_ENABLED=false` by default; signup and
  signup verification return 403 `signup_disabled` until enabled.
- `EMAIL_DELIVERY=log` is the default. It suppresses mail and records only the
  job UUID, never an address, body, or code. It does **not** print a login code.
- `EMAIL_DELIVERY=resend` needs `RESEND_API_KEY` and `RESEND_FROM_EMAIL`. Configure
  a verified sending identity before enabling real delivery. Missing Resend
  configuration fails startup only when Resend mode is explicitly selected.
- Clerk remains linked. No account is automatically marked verified from a
  stored address, invitation, Clerk identity, or password enrollment. A reset or
  verification code proves control of the stored email.
- Configure the immutable `OWNER_USER_ID`, or retain the existing configured
  exact owner API key ID. Prefix matching never grants quota exemption. Account exemptions are derived from that trusted
  configuration; no owner is inferred from signup order or email.
- Migrations 057–059 add tables/triggers and widen the background-job type
  constraint. They leave `users` columns unchanged because the overlapping old
  binary uses strict `SELECT *` scans. Old binaries do not know `auth_email` jobs;
  let the backend deployment drain before clients start using the new email
  routes. Do not roll an old worker back over a queue of new email jobs.
- No production settings were read or changed in this workstream. Before public
  signup, verify real delivery, the proxy trust chain, the owner exemption and
  E/F/G clients. Keep the public flag off until those are ready.

## Email proof

Codes contain six decimal digits, expire after ten minutes, and allow five
attempts. Proof consumption and its account mutation commit in one transaction.
A newly issued code invalidates the previous code for that purpose/address.
Wrong codes are also counted durably per normalized email and purpose across all
challenges: after ten wrong attempts in a rolling 24 hours, every code receives
`invalid_code` until the window reopens. New challenges do not reset this budget.
Initiation reserves at most five sends per rolling 24 hours and purpose. Delays
between sends increase to 60, 120, 240 and 480 seconds. Suppression preserves the
current challenge and returns the same generic 202. Retried delivery uses the
same outbox/idempotency key. A stranger can exhaust recovery for an address for
a day; password login remains usable. The server stores only a keyed code hash.
No sign-up password is stored before proof; choose and submit it with the code.

Initiation returns 202 with this exact generic body for eligible, unknown,
already-registered and resend-throttled addresses:

```json
{"message":"If this request is eligible, an email will arrive shortly"}
```

All proof endpoints return `Cache-Control: no-store`. Show the generic receipt;
do not tell a user an account exists or does not exist based on initiation.

| Method/path | JSON payload | Success |
| --- | --- | --- |
| POST `/auth/signup` | `email`, optional `name` | 202; starts signup or resends |
| POST `/auth/signup/verify` | `email`, `code`, `password` | 200; creates verified account/password, no session |
| POST `/auth/password/forgot` | `email` | 202; starts/resends reset |
| POST `/auth/password/reset` | `email`, `code`, `password` (new) | 200; verifies email, sets password, revokes **all** device sessions and API keys |
| POST `/auth/email/verify` | `email` (must be current account email) | 202; first-party session required |
| POST `/auth/email/verify/confirm` | `email`, `code` | 200; first-party session required |
| POST `/auth/email/change` | `email` (new), `current_password` | 202; first-party session/password required |
| POST `/auth/email/change/verify` | `email` (new), `code` | 200; same account session required; changes email, revokes all sessions and API keys |

A proof success returns `{"verified":true,"sign_in_required":true}` for signup,
reset and email change; ordinary email verification sets `sign_in_required` to
false. After success, sign in through the existing native or web password route.
Never store a code in local storage, analytics, crash reports, or URLs.

Passwordless existing accounts use **forgot password with their stored email**.
Reset works with or without a previous first-party password, verifies that email,
and preserves the stable user ID, library and Clerk link. A code is the required
proof; knowing an email alone does not create or link an account.

A reset or email change atomically deactivates every account API key, including
scoped agent and `capture:upload` keys, and queues a notice to the previous
address explaining that sessions and keys were revoked. Ordinary password changes
preserve API keys and queue a notice. Account deletion removes capture keys with
all other keys. Main has no separate session-bound capture-key table or deleted-
session key cleanup to update; account-level revocation covers every current key. These notices commit with the credential change. Changing
password invalidates outstanding reset/email proofs; an email-change challenge
is also bound to the exact reauthenticated password snapshot.

Proofs are single use. If a success response is lost, try signing in with the
new credentials; a repeated code receives `invalid_code`. Native session issuance
still supports its existing exact-successor retry contract.

## Passwords, onboarding and deletion

New passwords are NFC-normalized and must contain 12–128 Unicode characters.
The server checks [Have I Been Pwned](https://haveibeenpwned.com/API/v3#PwnedPasswords)
using only the first five SHA-1 hex characters and padded range responses.
A timeout/provider outage fails open. Full hashes and passwords are never sent.
Passwords remain stored with bounded Argon2id; existing bcrypt upgrades on login.

`POST /auth/password/login` is unchanged:

```json
{
  "email":"person@example.com",
  "password":"a sufficiently long password",
  "client_type":"ios",
  "device_name":"My phone",
  "next_refresh_token":"mta_rt_<persisted canonical random successor>"
}
```

`client_type` accepts `ios` or `android`; 201 returns the existing `AuthTokenPair`.
Persist the successor **before** sending and retry the same request after an
ambiguous response. Browser clients continue using the cookie prepare/finish
adapter, which never returns bearer credentials to JavaScript.

`POST /auth/password` now accepts `password` and `current_password`. The latter
is required when a password already exists. First enrollment from an existing
first-party session accepts just `password` only after its stored email is verified.
An unverified account receives 403 `email_verification_required`; use email
verification or forgot password to prove control. Replacement keeps the current
session and revokes all others, preserving API keys. A concurrent password replacement returns 409
`credential_changed` rather than trusting a stale verification.

`DELETE /account` retains `confirmation:"DELETE"` and optional
`deletion_receipt_token`, and now requires `current_password` when configured.
Passwordless first-party/Clerk accounts retain their existing deletion boundary.
An older client that cannot collect the current password receives a clear 401;
F/G/E must add that input before exposing replacement/deletion for password users.
Login and refresh payloads stay compatible with iOS build 13.

Verified email plus a configured password completes onboarding without passkeys
or recovery codes. The shipped passkey-plus-recovery completion path remains
accepted during the transition. `/auth/web/session/onboarding/status` adds
`email_verified` and `password_configured`; `complete` recognizes either path.
`GET /auth/me` adds `email_verified`. Passkeys/recovery remain optional security
and recovery methods; this work does not detach or remove Clerk.

## Browser recovery

- Use existing `/auth/web/session/password/prepare` and `/finish`, exact Origin,
  host-only cookies and the matching `X-CSRF-Token` header.
- A stale/revoked password successor returns 400 `sign_in_not_prepared` and
  clears its pending cookie. Call prepare once, then retry with the new cookie.
  An ordinary wrong password leaves the pending successor intact.
- A successful refresh renews the readable CSRF cookie's 365-day lifetime while
  preserving its value across tabs. It does not rotate a secret beneath a tab
  with an in-flight mutation.
- Exact old/new refresh retries still recover an interrupted response. Other
  consumed-token replays return 409 `session_refresh_in_progress` on native
  routes (or a retryable 503 `authentication_unavailable` on the web adapter);
  this non-revoking response applies only while the successor is unused. Once
  the successor has itself been consumed, reuse revokes the entire session and
  returns `invalid_session`, even for an exact old/new pair. This preserves build
  13's `next_refresh_token` recovery and browser pending-cookie recovery while
  detecting two parties advancing the same session.
- Cookie-authenticated mutations to the new signed-in email routes require the
  existing exact-Origin/double-submit checks. Signed-out JSON initiation is
  limited per normalized account and purpose and never authenticates from an email or code-less request.

## Usage

`GET /auth/usage` requires an interactive account session and returns:

```json
{
  "month":"2026-11-01T00:00:00Z",
  "transcription_seconds":60,
  "transcription_limit_seconds":18000,
  "ai_requests":2,
  "ai_request_limit":1000,
  "exempt":false
}
```

Months reset at the UTC calendar boundary. Defaults are
`DEFAULT_MONTHLY_TRANSCRIPTION_MINUTES=300` and `DEFAULT_MONTHLY_AI_REQUESTS=1000`.
Defaults are captured in an account policy on first use; later per-account limit
overrides survive ordinary requests. Owner exemption is refreshed from server
configuration. Usage is account-wide across interactive sessions and owned API
keys; old unowned keys retain their existing behavior until linked to an account.

Admission checks precede uploads, video extraction/batches, retry, summaries and
chat. New pending media reserves one minute in the creation transaction. A batch
that exceeds capacity rolls back all items/jobs. The worker replaces that
provisional minute with rounded-up actual seconds before paid Whisper work;
video metadata is checked before subtitle extraction/Whisper fallback. A capped
account with unknown duration fails closed. If the recording is larger than its
remaining balance, an accepted asynchronous item ends failed with a limit
message; the upload request cannot know its duration yet. A failed provisional
item releases its minute. Once actual provider work is authorized, that duration
stays charged, including failures/retries of the same resource. Resource/month
reservations make retries and restarts idempotent. Deleting media does not refund
processed minutes. Usage includes queued reservations, so it may fall after a
provisional item fails or its actual duration proves shorter.

Summaries, chat, automatic titles/summaries and readability formatting share a
separate monthly AI request cap. HTTP errors refund a reservation only when no
provider call occurred. Provider transport failures, malformed output, citation
validation failures and post-call database failures stay charged. Accepted
asynchronous summaries retain their reservation. Manual formatting is checked at
HTTP admission and charged by its durable worker, exactly as automatic formatting
is. Each automatic title, summary and formatting operation reserves a request
before its provider call. Durable job/operation keys prevent double charges on
restart. Capped enrichment ends with `summary_status` or `formatting_status` set
to `skipped` and a clear limit message; the transcription remains `completed`.
Formatting requeue checks the cap at the database boundary as well as over HTTP.
Workers initialize missing policies from the server defaults and exact owner
configuration, so pre-rollout queued enrichment also counts.

All client-supplied `model` overrides are allowlisted server-side. Omit the model
to use the operator's default, or use `openai/gpt-4o`, `openai/gpt-4o-mini`,
`google/gemini-2.5-flash`, `google/gemini-2.5-flash-lite`, or
`anthropic/claude-4.5-sonnet-20250929`. This covers the choices on current main:
iOS sends nil, web defaults to no override and documents GPT-4o, and CLI defaults
to no override. CLI's arbitrary `--model` is intentionally restricted for capped
accounts. Unknown choices return 400 `invalid_model` before provider work. Only
the owner account, identified by `OWNER_USER_ID` or exact `OWNER_API_KEY_ID`, may
request any model. A matching key prefix never grants this permission.

## Stable errors

| HTTP | `error` | Client action |
| --- | --- | --- |
| 400 | `invalid_model` | Choose an allowed model or omit it |
| 400 | `invalid_request` | Correct the payload |
| 400 | `weak_password` | Use 12–128 characters |
| 400 | `password_compromised` | Choose a different password |
| 400 | `invalid_code` | Code invalid, expired, consumed, or attempts exhausted; offer resend |
| 400 | `sign_in_not_prepared` | Prepare browser password sign-in again |
| 401 | `invalid_credentials` | Generic email/password rejection |
| 401 | `current_password_required` | Collect the current password |
| 402 | `monthly_transcription_cap` | Show usage and next UTC month boundary |
| 402 | `monthly_ai_cap` | Show summary/chat usage and next UTC month boundary |
| 403 | `email_verification_required` | Prove the stored email before first password |
| 403 | `signup_disabled` | Hide signup; keep existing sign-in |
| 403 | `csrf_invalid` | Refresh browser preparation/session state |
| 409 | `password_required` | Enroll a password before email change |
| 409 | `credential_changed` | Sign in again; credentials changed concurrently |
| 429 | `rate_limit_exceeded` | Honor `Retry-After`; preserve local input |
| 503 | `authentication_unavailable`, `usage_unavailable` | Keep state and offer retry |

The account failure bucket applies to unknown and known addresses alike, and
only to rejected passwords. A correct password remains usable after bad guesses.
Password and email flows do not use a shared IP bucket. Other public ceremonies
use secondary IP throttles only when a client-IP source has been verified.

## Proxy trust and served HTML

Client-IP trust has three explicit sources. Gin's implicit proxy trust is disabled.

- `RENDER_CLIENT_IP_ENABLED=false` by default. Enable only on the public Render
  web service behind its managed edge. Render documents that Cloudflare
  overwrites `CF-Connecting-IP`, while callers can forge the first value in an
  appended `X-Forwarded-For` chain. The code uses that documented overwritten
  header, never a caller-selected leftmost address. Private Render traffic and
  directly exposed deployments must leave the flag off. See
  [Render's client-IP and spoofing guidance](https://render.com/articles/host-pocketbase-on-render).
- `NETLIFY_PROXY_SIGNATURE_SECRET` must be the same secret on Render and Netlify
  (Runtime scope). `netlify.toml` configures `signed` on `/api/*`. The server
  validates the `X-Nf-Sign` JWT's HS256 signature, `iss=netlify`, and required
  expiry before trusting the single `X-Nf-Client-Connection-Ip` value. An unset
  secret, invalid/expired JWT or malformed IP cannot authorize that header. It
  authenticates the proxy, never an account. See
  [Netlify's signed-proxy contract](https://docs.netlify.com/manage/routing/redirects/rewrites-proxies/).
- `TRUSTED_PROXY_CIDRS` remains available for other explicitly verified socket
  peers. It walks `X-Forwarded-For` right to left and stops at the first untrusted
  hop. Never allow `0.0.0.0/0`, `::/0`, or guessed broad private networks.

Netlify evaluates `_redirects` before `netlify.toml`, first match wins. The domain
and SEO rules remain in `_redirects`; the API rule and SPA fallback now live in
TOML so a `_redirects` catch-all cannot shadow the signed proxy.

With no verified source, the socket address remains diagnostic only: public auth
IP throttles skip it rather than sharing one proxy bucket. Durable per-account
password and email limits remain active. Release startup logs a clear warning
when no source is configured and continues serving traffic. No production config
was inspected. Rollout still needs real direct-Render and Netlify spoof checks.

Go-served HTML now has CSP restricting scripts, frames, objects and form actions.
Swagger permits its one static initialization script by hash. E must add the
corresponding policy to **Netlify-served** HTML headers and verify Clerk's
remaining bridge origins during rollout. API response headers cannot protect a
separately served Netlify document.

## Email jobs and operational data

Mail uses [Resend POST /emails](https://resend.com/docs/api-reference/emails/send-email):
Bearer authorization, `from`, a `to` array, plain `subject`/`text`, and stable
`Idempotency-Key: auth-email/<outbox UUID>`. Network errors, 429 and 5xx retry via
the existing durable job system (eight attempts, at least 30 seconds, respecting
`Retry-After`). Provider bodies and transport errors never enter logs. Expired,
consumed and superseded challenges are not deliverable. Delivered encrypted
payloads are cleared. AES-GCM envelopes and code HMACs derive distinct keys from
`JWT_SECRET`; rotating that secret invalidates pending codes/mail.

Auth audit records contain route, outcome, stable user ID where available, and
time; no request payloads or addresses. Events retain 90 days. Expired access and
refresh tokens, expired proof/outbox material and old failure buckets purge at
startup and at most hourly on auth traffic. Consumed **unexpired** refresh rows
remain for response-loss recovery. There is no idle database polling loop.

Tests use fake Resend and HIBP transports. The local HTTP acceptance fixture has
a code-reading hook defined exclusively in `_test.go`; it cannot appear in the
release server. No real email was sent and no Resend key was sought.
