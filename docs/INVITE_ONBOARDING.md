# Invite-only onboarding and rescue

First-party accounts are created from one-time invitations. Email identifies
who the invitation is for, but authentication is always bound to the immutable
`users.id` created during redemption. The server does not link identities by
matching an email address.

## Create an invitation

Call `POST /api/v1/auth/invitations` with the configured `X-Admin-Key` and a
name and email. The response contains a `https://media.shimizu-technology.com/join#invite=...`
URL for manual secure sharing. The fragment keeps the token out of normal HTTP
requests, server logs, and referrer headers. The client must immediately move
it into its protected onboarding journal or cookie and clear the fragment from
the address bar.

Creating another invitation for the same normalized email revokes all older
unused invitations for that email. A redemption racing a replacement is
serialized: either the original invitation creates the account, or the new
link replaces it. Both links cannot create accounts.

## Rescue an incomplete account

An invitation can create the user and device session before the person finishes
adding a password or passkey and recovery codes. If that browser or device is then lost, an
administrator can call `POST /api/v1/auth/onboarding/reissues` with the exact
`users.id`. The server issues a 24-hour
`https://media.shimizu-technology.com/join#onboarding=...` URL only when the
account has:

- zero passkeys; and
- no configured password; and
- zero active unused recovery codes.

This is deliberately unavailable for a normally secured account. Its regular
password, passkey, or recovery-code flow must be used instead.

The rescue token is one use, stored only as a SHA-256 hash, and replaces older
unused rescue links for that user. On redemption, the client-generated refresh
credential and the new session are committed together, and every older device
session for the user is revoked in the same transaction. If the successful
response is lost, retrying the exact token and saved refresh successor within
24 hours recovers the same session with a fresh access token.

Raw token responses accept only iOS and Android. The web join flow must use its
same-origin HttpOnly cookie adapter so refresh and access credentials never
enter browser JavaScript.

## Operator rules

- Share invitation and rescue URLs through a private channel. They are bearer
  credentials until used or expired.
- Confirm the immutable user ID before creating a rescue. Do not select an
  account by email alone.
- After rescue, require passkey enrollment and confirmed recovery-code setup
  before treating onboarding as complete.
- Do not use rescue to bypass a working recovery method. The server enforces
  this at both creation and redemption in case account state changes.
