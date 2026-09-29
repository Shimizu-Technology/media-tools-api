# Browser session rollout

The browser can exchange a current Clerk sign-in for a first-party Media Tools
session. Existing `users.id`, media ownership, and developer API keys stay the
same. Clerk remains available for initial sign-in while passkey login is built.

## Deployment order

1. Deploy migrations 043 and 044 and the API code. Set
   `FIRST_PARTY_AUTH_ENABLED=true` and `WEB_COOKIE_AUTH_ENABLED=true` on Render.
   Keep `CLERK_JWKS_URL` and `CLERK_SECRET_KEY` configured.
2. Set `CORS_ORIGIN` to the exact canonical web origin,
   `https://media.shimizu-technology.com`. Include every intentionally
   supported preview origin as a comma-separated entry. Browser session
   mutations reject requests from origins absent from this list. The old
   `media-tools-gu.netlify.app` host redirects to the canonical host so saved
   Home Screen links use the same cookie origin.
3. Verify that Netlify serves `/api/v1/health` through the same-origin `/api/*`
   proxy before enabling the browser flag. The public `frontend/public/_redirects`
   proxy targets the current Render API and precedes the SPA fallback.
4. Set `VITE_WEB_COOKIE_AUTH_ENABLED=true` and leave `VITE_API_URL` empty for the
   Netlify build. Rebuild and deploy the frontend. Sign in once through Clerk,
   then verify `/api/v1/auth/web/session/status` returns authenticated after a
   reload and after Clerk's seven-day session expires.

Access and refresh cookies are host-only, `HttpOnly`, `SameSite=Strict`, and
`Secure` in release mode. The browser receives a separate readable CSRF cookie
and sends its value in `X-CSRF-Token` for mutations. The refresh credential
never enters JavaScript. A prepared successor cookie makes a lost refresh
response retryable without revoking the session. The web session lasts up to
365 days of inactivity, with 15-minute access credentials. Sign-out revokes
the current device session and clears its cookies.

## Rollback

Turn off the frontend flag first so the browser returns to Clerk bearer auth.
Existing first-party browser cookies are ignored in that mode. Turn off
`WEB_COOKIE_AUTH_ENABLED` on the API after web traffic has stopped using the
cookie endpoints. Keep `FIRST_PARTY_AUTH_ENABLED` on while native clients use
first-party device sessions. Do not remove migrations or delete session rows
during rollback.

This flag does not replace Clerk sign-in or enable passkey login. Do not switch
off Clerk until another verified login path is deployed and existing accounts
are tested through that path.
