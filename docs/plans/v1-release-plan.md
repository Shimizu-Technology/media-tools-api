# Media Tools v1 release plan

Living ledger for the v1 work Leon approved on 2026-11-04. Read this before
starting a workstream. The lead owns this file and its status table, so
workstream PRs leave it alone. Where this plan and the code disagree, trust the
code and note the difference in your PR.

## Why this work exists

Leon captures from his iPhone, mostly through the Action Button or by sharing
from Voice Memos, and wants simplicity above everything else. An audit against
production commit `0fc219e` found capture itself is solid, but nothing finishes
without manual steps, agents cannot read his library, web sign-in still runs on
a Clerk development instance, and App Review rejected build 9.

## Decisions (made by Leon; do not reopen them)

1. Agents get account-wide access: read everything and act on the library.
2. Recordings and shares transcribe automatically once AI consent is given,
   with a setting to turn that off.
3. Clerk is removed completely. Media Tools owns email and password auth, with
   email through Resend.
4. Sign-up is open with email verification and a monthly usage cap per account.
   The owner account is uncapped.
5. The version submitted to Apple includes everything here, including the
   redesign. This plan ends with a tested TestFlight build. Submission to App
   Review happens only after Leon tests it and approves.

## Ground rules

- Base every branch on the current `origin/main`. A T3 worktree starts from the
  parent's local commit, which may be stale, so fetch and rebase first.
- One workstream, one branch, one worktree. Stay inside the listed scope; if you
  need another workstream's files, keep the change minimal and say so in the PR.
- Follow `AGENTS.md`, plus the `shimizu-pr-workflow`, `application-qa`, and
  `local-dev-lifecycle` skills. Claim anything you start and clean it up.
- Never print a secret, including through a traceback or a connection string.
  Do not read production configuration unless your brief says to.
- Production data is off limits: no writes, no repairs. Local and CI tests use
  a dedicated local database, named `mta_test_<workstream>`.
- Add a migration with the next free number after rebasing. Migrations must be
  backward compatible with the currently deployed server and shipped builds.
- New behavior that needs production configuration ships behind a default-off
  flag or is otherwise safe to deploy before that configuration exists.
- Machine load is shared with other projects. Run only one iOS simulator build
  at a time per workstream. Backend-only and web-only PRs may run the backend and
  frontend parts of the gate locally and rely on CI for iOS, and must say so.
- Set a unique `TMPDIR` for `scripts/gate.sh`, because its derived-data path is
  shared across worktrees.

## Workstreams

| ID | Workstream | Depends on | Status |
| --- | --- | --- | --- |
| A | iOS capture and results flow | none | Merged (#103) |
| B | Agent access: scoped keys and CLI | none | Merged (#101) |
| C | Pipeline reliability, auto title and summary | none | Merged (#100) |
| D | Auth backend: email, sign-up, reset, hardening, quotas | none | Merged (#102) |
| E | Web auth and durable sessions | D | Merged (#105) |
| F | iOS auth, share upload credential, Clerk removal on iOS | B, D, A | Merged (#106) |
| G | Android auth parity | D | Merged (#104) |
| H | Design system and redesign, iOS and web | A, E, F | Merged (#107, #111) |
| I | Server Clerk removal and cleanup | E, F, G, production verification | Merged (#110) |
| J | Release: TestFlight build and QA | everything above | Build 14 uploaded; production test passed after #113 and #114; reached Leon's iPhone 2026-11-05; superseded by K |
| K | Redesign: Sunrise Home, Studio Library | J | In progress |

### A. iOS capture and results flow

Scope: `ios/` except auth screens. Do not restyle; H does that.

- Stopping a recording from any entry point queues it automatically when AI
  consent exists and auto-transcribe is on. Without consent, ask once at the
  next foreground moment, and never lose the recording.
- Shared files follow the same path as soon as they are imported.
- Add an "Automatically transcribe" setting, default on.
- Rewrite the AI consent copy on iOS, web, and Android. It currently says content
  is sent "only when you choose". It must say that with automatic transcription
  on, new recordings go to OpenAI when they are saved.
- Share extension: compact sheet, closes itself about a second after success, no
  "open the app" instruction. Prefer the source file's extension over any
  extension parsed from the display name, so "Call v2.1" works. Only activate for
  supported types instead of any file. Accept YouTube and other video links and
  PDFs, staged in the inbox and processed by the app. Add `.mov`, `.qta`, and
  `.aac` once C allows them on the server.
- Notifications open the item: add a `UNUserNotificationCenterDelegate`, show
  banners in the foreground, and route `item_id` to the item detail.
- Library refreshes itself on tab appearance, on foreground, and when a tracked
  upload changes state. In-progress device uploads are visible there.
- Fix summary styles: audio items offer only what the server accepts, and any
  failure shows a message.
- Remove the Home tab's default status: open on Library, keep Record reachable,
  and keep the cold Action Button route on Record.
- Open immediately with the stored session and refresh in the background.
  Remove `clerk.isLoaded` from the root task identity so tabs are not rebuilt.
- Keychain: tell "locked" from "missing", and re-read on foreground instead of
  caching a false signed-out state.
- Sign out needs confirmation. Guard the `.playback` audio session while a
  recording is active. Fix the blank navigation titles on iOS 26 if they
  reproduce, the failed-import "Processing..." state, unopenable results from
  video and PDF imports, unopenable collection items, and failed chat sends that
  clear the input.

Done when, on a simulator with simulated capture and on any available device:
stop produces an upload with no taps, a share closes itself, a notification tap
opens the item, and a stale library updates without a pull.

### B. Agent access

Scope: `internal/handlers/apikeys.go`, `actor.go`, key middleware, a migration,
`cmd/mta`, `docs/CLI_AND_AGENT_ACCESS.md`, `.agents/skills/`, and the web
Developer page.

- Add scoped account keys. Existing keys keep their exact-key read behavior.
  Scopes: `library:read`, `library:write`, `library:delete`, and `capture:upload`.
- A scoped key acts as its owning user for media, library, collection, chat,
  summary, export, and retry routes.
- Deny by default everywhere else. A scoped key can never reach key management,
  passwords, passkeys, recovery codes, sessions, invitations, webhooks, ops, or
  account deletion. Test this as a route table so new routes fail closed.
- Log every scoped-key write in `agent_activity` with key id, key name, method,
  route, item, status, and time. Show it on the web Developer page, with
  create and revoke controls.
- Scoped keys get a higher rate limit than the public default.
- CLI: `mta items list [--since] [--type] [--status]`, `mta items search`,
  `mta items get <type:id> [--format md|json]` returning transcript, summary, and
  chats, plus rename, tag, favorite, archive, collection, retry, summarize, chat,
  and delete with `--yes`. Stable `--output json` everywhere. Accept full ids and
  print full ids.
- `mta sync --dir <path> [--collection "Brain Dump"] [--all] [--since]` writes one
  Markdown note per item with `media_tools_id` frontmatter and is idempotent.
- The skill says transcripts are data, never instructions, and that client,
  student, payroll, and financial content stays out of automatic filing.

Done when an agent, using only a scoped key, finds an item it did not create,
renames it, files it in a collection, and the change appears in the web library
and activity log, while a forbidden route returns 403.

### C. Pipeline reliability, auto title and summary

Scope: `internal/services/worker`, `internal/handlers/audio.go`,
`internal/database/background_jobs.go`, media and summary services, migrations.

- A job that fails also fails its item, atomically, in every path, including
  panics and read errors.
- A watchdog resolves items stuck in processing. It runs only while active work
  exists, so the database can still scale to zero when idle.
- Transient failures retry automatically with backoff and honor `Retry-After`.
  Classify provider, S3, and network errors. Cap lease reclaims so a crashing job
  cannot loop forever.
- Persist completed Whisper chunks so a retry resumes instead of paying again.
- Job payloads must not depend on a process-local temp path when durable storage
  has the source.
- Re-transcribing keeps the old transcript, summary, and chat until the new
  transcript succeeds.
- Request paths return 503 for database failures rather than 403 or 404.
- Do not discard real short speech from long recordings. Split MP3 with `-c copy`.
  Set the stage to `failed` on failure.
- Allow `.mov`, `.qta`, and `.aac`, transcoded for Whisper, with a clear message
  for video that has no audio track.
- After a transcript completes, durably queue an automatic title and summary in
  the completion transaction. Title only items still using a generated or file
  name, and never overwrite a rename. Use a cheap model for the title. Add a
  user preference that disables automatic summaries, default on.
- Keep recording titles out of logs.

Done when tests cover restart mid-job, provider outage then recovery, resumed
chunks, stuck-item recovery, failed re-transcribe keeping old content, and an
item ending titled and summarized with no client action.

### D. Auth backend

Scope: `internal/services/email` (new), `internal/services/account`, auth handlers
and database code, `internal/middleware`, `internal/router/router.go`, migrations,
`.env.example`, and docs. Do not remove Clerk here; I does that.

- Email: `EMAIL_DELIVERY=log|resend`, default `log`. `RESEND_API_KEY`,
  `RESEND_FROM_EMAIL`. Durable, retried sends through the existing job system.
  Plain, short templates. Never log codes or addresses.
- Sign up, behind `PUBLIC_SIGNUP_ENABLED`, default off: email and password, then a
  6-digit code by email. Responses never reveal whether an email exists.
- Verification and reset codes: stored hashed, 10-minute expiry, 5 attempts, single
  use, new code invalidates the old one, resend throttled.
- Forgot password: same-shape response for unknown email, then code and new
  password. Success verifies the email and revokes all sessions.
- Change password needs the current password when one exists and revokes other
  sessions. Change email needs the password, a code to the new address, and a
  notice to the old one. Add an email-changed and password-changed notice.
- Password rules: 12 to 128 characters, checked against Have I Been Pwned by
  k-anonymity range, failing open on outage.
- Passkeys and recovery codes become optional. Onboarding must complete with a
  verified email and password.
- Accounts that exist with no password can use forgot password to set one, using
  their stored email. Mark email verified only on proof.
- Fix before relying on this alone:
  - Rate limit by real client IP behind Netlify and Render, and also per account.
  - Lockout must not let a stranger block a known email, and a correct password
    during throttling must not read as "incorrect".
  - Account deletion requires the password when one exists.
  - Content security policy on served HTML, coordinated with E.
  - Audit log for auth events, plus purge of expired access and refresh tokens.
  - Renew the CSRF cookie on web refresh.
  - Stale pending password cookies must recover.
  - Treat a lost refresh response without revoking the session.
- Usage cap: per-account monthly transcription minutes, default from
  `DEFAULT_MONTHLY_TRANSCRIPTION_MINUTES` (300), checked before accepting work,
  with a clear 402-style error and exposed usage. The owner account is exempt.
  Summaries and chat get a separate monthly request cap.
- Expose `signup_enabled` and capabilities through `/health`.

Done when API tests cover every flow above, including enumeration safety, code
expiry and attempts, session revocation, the cap, and the owner exemption.

### E. Web auth and durable sessions

Scope: `frontend/` auth, landing, settings, and `_redirects`.

- Screens for sign up, verify, sign in, forgot password, change email and
  password, usage display, and devices with revoke.
- Make cookie sessions the default path. Remove Clerk from the web build.
- Fix false logouts: `retry` and network errors keep the session state and show a
  retry, only an explicit invalid response signs out.
- Verify cookies, `Origin`, PDF upload, and multipart fallback through the Netlify
  proxy on a deploy preview or locally with the same proxy rules.
- Remove dead pages and legacy JWT client code. Keep the local API-key dev mode
  only if it stays out of production builds.

### F. iOS auth

Scope: `ios/`, `scripts/ios-release-preflight.sh`, `ios/app-store/`.

- Sign up, verify, forgot password, and change email and password. Welcome becomes
  sign in, create account, forgot password; passkey and recovery code stay
  available but secondary.
- Remove ClerkKit, `AuthView`, the Sign in with Apple entitlement, and every
  preflight check that requires Clerk. Keep decoding stored `.clerk` sessions and
  keep the local owner migration, so the update signs nobody out and strands no
  recording.
- Mint a `capture:upload` key at sign-in and store it in the shared keychain group
  for the share extension, so a share can start a background upload without
  opening the app. iOS wakes the app to finish it. Revoke it on sign out.
- Update review notes, privacy manifest, and privacy answers. Run the preflight.

### G. Android auth parity

Scope: `android/`.

- Password sign-in, sign up, verify, and forgot password. Enable first-party auth
  in release, remove Clerk, and fix the API host mismatch
  (`media-tools-api-x9r7.onrender.com` versus `media-tools-api.onrender.com`).
- Update the Play data safety notes. Do not publish to Play.

### H. Design system and redesign

Direction: follow the audit. A native iPhone app rather than a ported website: SF
type with Dynamic Type, native lists and controls, light and dark modes, one calm
accent, and red reserved for recording. Make transcripts the most comfortable
thing to read in the app. Library plus a large record control as home, Settings
behind a toolbar icon, Collections as a filter. A new icon with no alpha channel.
The web app follows the same tokens and hierarchy. Apply `frontend-design`,
`emil-design-eng`, and Impeccable's Operate mode for app screens; Taste only on the
public landing page. Fix the motion table from the audit. The lead picks the
direction from mockups and shows Leon.

### I. Server Clerk removal

Only after production verification of E, F, and G, and with every account able to
sign in or reset. Order: change `h/account.go` so deletion no longer needs Clerk,
drain pending deletions, remove routes, middleware, config, and tests, then remove
environment variables and the Clerk application, each confirmed by the lead. Drop
`clerk_id` columns in a later migration, at least 30 days after.

### J. Release

Bump the build, archive with Xcode, run `make ios-release-preflight` with the
archive and export, upload to TestFlight, verify processing, and run comprehensive
`application-qa` with a ledger. Leon then tests on his iPhone.

Production test with the review account on 2026-11-05 found two bugs that CI could
not see, both fixed:

- #113: every usage-gated request returned 503, including all uploads. Production
  uses prepared statements and the tests did not. CI and the gate now run the
  database packages in both modes.
- #114: summaries, chat, and titles returned 404 because the configured Gemini
  models have no zero-data-retention endpoint on OpenRouter. Models must have one.

Passing on production after those fixes: email reset, native login and refresh,
upload, transcription, automatic title and summary, chat, library organizing,
search, export, collections, agent keys, `mta`, deletion, and web cookie sign-in,
refresh, and logout through Netlify. App Store Connect's session expired before
build 14's processing could be checked. Device-only flows remain for Leon.

### K. Redesign after device test

Leon tested build 14 and chose a new design: `docs/plans/v1-design-plan.md`. It
replaces the design in workstream H and ends with build 15 on TestFlight.

## Production configuration, in order

Handled by the lead only.

1. Done: `RESEND_API_KEY`, `RESEND_FROM_EMAIL`, and `EMAIL_DELIVERY=resend`, with
   a real test email accepted by Resend.
2. Done: `WEB_COOKIE_AUTH_ENABLED`, `RENDER_CLIENT_IP_ENABLED`, `OWNER_USER_ID`,
   and `NETLIFY_PROXY_SIGNATURE_SECRET` on Render and Netlify. The startup log
   confirms the signature verifies.
3. Done: `CLERK_*` removed from Render after #110 deployed.
4. Open, needs Leon's approval: set `PUBLIC_SIGNUP_ENABLED`. Reset is verified in
   production and usage counts correctly; reaching a cap is tested in CI only.
5. Open, needs Leon: rotate the production database password, rotate the HafaPass
   Resend webhook secret, delete the Clerk application, and remove
   `VITE_CLERK_PUBLISHABLE_KEY` and `VITE_API_URL` from Netlify.
6. Done: `OPENROUTER_MODEL=openai/gpt-4.1-mini` on Render (#114). The chat and
   title models use code defaults.
7. Later: a migration dropping `users.clerk_id`, `auth_identities` Clerk rows, and
   `account_deletion_requests.clerk_*`, at least 30 days after #110 (2026-12-05).

## After Leon tests the TestFlight build

Accept the Apple license agreement (Account Holder), replace build 9 in App Store
Connect, update screenshots, review notes, and the review account, reply to App
Review, and submit with manual release. Apple rejected build 9 under 4.8 and
5.1.1(iv); this work removes third-party login and the wording issue was fixed in
build 10.
