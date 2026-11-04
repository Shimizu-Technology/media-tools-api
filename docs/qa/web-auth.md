# Web auth and durable sessions: QA ledger

Workstream E. Stacked on the auth backend (PR #102). Application: Media Tools web,
where people sign in to a private library of recordings, transcripts and PDFs.
Sources: v1 release plan section E and ground rules, `docs/AUTH_API.md`,
`docs/WEB_SESSION_ROLLOUT.md`, `docs/AUTH_BACKEND_QA.md`. Executor: implementation
agent (agent-executed; Leon has not walked it). No production configuration or
data was read. All accounts are synthetic, on local PostgreSQL 16 `mta_test_web`.

## Environment

- Production frontend build (`npm run build`, no auth variables) served by a
  local stand-in for Netlify built from the repo's own `netlify.toml` and
  `_redirects`: static files first, `/api/*` proxied with status 200 and a
  signed `X-Nf-Sign` header, SPA fallback, `[[headers]]` applied to static
  responses. Origin, `Cookie` and `Set-Cookie` pass through untouched.
- Real Go server (debug build), `EMAIL_DELIVERY=log`, `WORKER_COUNT=0` so no
  mail job clears its sealed payload. Codes were read by a throwaway
  `_test.go`-only helper (same approach as the router fixture) and filled
  into the page by script, so no code was printed or logged.
- Browser: T3 preview at 390x844 (phone) and 1280x800. Outages simulated in the
  proxy (`drop` closes the socket, `503` returns an HTML error page, `strip1`
  removes the access cookie once, as an expired 15-minute cookie would be).

## Scenarios

| ID | Scenario | Result |
| --- | --- | --- |
| W01 | Sign-up: email, generic receipt, code + password, wrong code, breached password, then success, then sign in | Passed (phone) |
| W02 | Sign-up hidden and `/sign-up` explains itself when `signup_enabled` is false | Passed |
| W03 | Sign in (wrong password, right password), reload keeps session, sign out | Passed |
| W04 | Existing account with no password and `onboarding_required`: sign-in page points to "Set or reset my password", reset sets password and verifies email, lands in `/app` not `/join` | Passed |
| W05 | Forgot password for an account with a password; reset revokes another device (status 401 on the old cookie jar) | Passed |
| W06 | Change password with current password | Passed |
| W07 | Change email: password, code to new address, all sessions end, sign-in page prefilled with the new address and a notice | Passed |
| W08 | Usage display (minutes and requests, next UTC reset) | Passed |
| W09 | Devices list and revoke of another device, and revoking the current device lands on sign-in | Passed |
| W10 | Delete account asks for the password; wrong password rejected; correct password deletes and signs out | Passed |
| W11 | Cold load while the API returns 503: "Can't reach Media Tools", not the sign-in form; returns by itself within one backoff step once the API is back | Passed |
| W12 | Mid-session outage (socket dropped): banner with retry, session and page intact, banner clears after retry | Passed |
| W13 | Expired access cookie: 401, prepare, refresh, replay, page unaffected | Passed |
| W14 | PDF upload through the proxy (multipart, Origin, CSRF, cookie reach the API) | Passed |
| W15 | Audio upload: presign fails, then the multipart fallback (3 MB body) reaches the API with Origin, CSRF and cookie | Passed to the API; local server has no `OPENAI_API_KEY`, so transcription itself was not run |
| W16 | CSRF and Origin: mutation without `X-CSRF-Token` 403, foreign Origin 403 | Passed (curl through the proxy) |
| W17 | Strict CSP from `netlify.toml` applied to the served HTML: pages, fonts and API calls ran with no violation reported by the browser | Passed on the paths above |

Not run: passkey and recovery-code sign-in (the API pins the relying party to the
production domain, so passkeys cannot work on localhost); first-password creation
for a passwordless account that is already signed in (needs a passkey or recovery
session); a video page with the YouTube embed under the CSP; real email delivery;
a real phone.

## Netlify-specific, not verifiable locally

- Whether Netlify passes multiple `Set-Cookie` headers through a signed
  status-200 proxy, and whether it applies `[[headers]]` to proxied responses.
- Request and response body size limits and the proxy timeout for large
  multipart uploads. The 3 MB test is small; the app prefers a direct presigned
  S3 upload and falls back to the API only when that fails.
- That real `X-Nf-Sign` / `X-Nf-Client-Connection-Ip` values validate against
  `NETLIFY_PROXY_SIGNATURE_SECRET`. The stand-in signs with the same HS256 shape,
  and the server accepted every call, but client-IP effects were not observed.
- The CSP against any deploy-only script injection (Netlify analytics, snippets).
  S3 uploads need `connect-src https://*.amazonaws.com`, which is in the policy.

## Gaps and follow-ups

- The device list has no "this device" marker, because the API does not say which
  session is current. Revoking it signs this browser out; the copy warns about
  that. A `current: true` field on `GET /auth/sessions` would fix it.
- AI-processing consent was stored under the Clerk subject for some existing
  users. The migration to the stable user id was Clerk-only code and is removed,
  so those users are asked once again.
- Old Clerk cookies and local storage left in browsers are inert and not cleaned
  up. The stored `mta_jwt_token` is removed at startup.
