# Auth backend acceptance

Workstream D, agent-executed backend QA. Initial base: `0fc219e`; rebased onto foundation `d570f70`, pipeline merge `896102f`, then agent-access merge `ac8ac9d`, 2026-11-04.
Media Tools saves recordings, video transcripts and PDFs into an account library
for search, summaries and chat. Sources: repo AGENTS.md, v1 release plan section D,
PASSKEY_AUTH.md, INVITE_ONBOARDING.md, WEB_SESSION_ROLLOUT.md, and Brain Dump
`work/shimizu-tech/company-positioning-and-project-review-2026-10-04.md`.
Existing clients use recoverable first-party device sessions; Clerk remains a
migration bridge. No production configuration or data is part of this run.

Required scenarios (local PostgreSQL 16 `mta_test_auth`, HTTP and integration tests):

- D01: unknown/existing email initiation has the same response; defaults disable signup.
- D02: signup → resend/verify → password login; email proof completes onboarding without passkeys.
- D03: expiry, five attempts, single use, resend throttle, concurrent redemption.
- D04: passwordless existing account resets through its stored email; reset verifies email and revokes sessions.
- D05: password/email changes and deletion require current password; notices are queued atomically.
- D06: bad logins cannot lock out a correct password; proxy-header spoofing cannot evade limits.
- D07: browser refresh renews CSRF, stale password pending state recovers, lost refresh responses do not revoke devices.
- D08: durable encrypted email jobs retry via fake Resend transport; no real sends or secret logging.
- D09: monthly transcription and summary/chat caps reject excess work; owner bypass; concurrent reservations.
- D10: purge removes expired tokens while preserving usable refresh recovery.

Pre-review acceptance: **10/10 passed** at the original head. This is historical
evidence; the review-fix acceptance below supersedes the affected contracts.
Execution uses local PostgreSQL 16,
full Gin routes over ephemeral loopback HTTP listeners, and synthetic accounts.

| Case | Result and evidence |
| --- | --- |
| D01 | Passed: `TestAuthHTTPDefaultsEnumerationAndVerification`, `TestEmailSignupAndQuotaDefaults` |
| D02 | Passed: same HTTP test; persisted verified account, successful native login, no passkey/recovery setup |
| D03 | Passed: `TestAuthHTTPVerificationExpiryAttemptsAndResend`, `TestEmailChallengeConcurrentSingleUseAndPurge` |
| D04 | Passed: `TestAuthHTTPPasswordlessResetChangesAndDeletion`; seeded passwordless Clerk-linked account, proved stored email, preserved stable ID/link, invalidated old session |
| D05 | Passed: same HTTP test plus `TestEmailProofBoundToCredentialSnapshotAndAccount`; missing/wrong password rejected, current session retained on password replacement, other sessions revoked, three notices queued, email change revoked all sessions, deletion persisted |
| D06 | Passed: `TestAuthHTTPFailedGuessesDoNotLockCorrectPassword`, `TestClientIPTrustBoundary`; failed guesses reach 429 and correct password succeeds; untrusted forwarded headers ignored |
| D07 | Passed: `TestAuthHTTPBrowserCSRFAndStalePendingRecovery` and session database regression tests; extended CSRF cookie, cleared stale pending cookie and completed fresh sign-in; stale refresh did not revoke successor |
| D08 | Passed: email service tests and `TestDurableAuthEmailRequeueAndDelivery`; fake Resend 429 requeued durably with Retry-After, replacement worker completed with stable idempotency key, ciphertext cleared, log delivery contained neither address nor code |
| D09 | Passed: `TestAuthHTTPUsageAndOwnerExemption`, `TestUsageAtomicConcurrentCapsMonthAndOwner`, `TestUsageAdmissionBatchRollbackAndFailedProvisionalRefund`, `TestAutomaticAIReservationsShareCapAndRecoverWithoutDoubleCharge`, `TestAutomaticEnrichmentChecksCapBeforeProvider`; two HTTP submissions completed through a synthetic extractor and exhausted 120 seconds, next transcription rejected 402, summary/chat rejected at their cap, a scoped agent key received the same 402 and could not change the password, owner bypassed cap, concurrent reservations respected limits, rejected batch left no items/jobs |
| D10 | Passed: `TestEmailChallengeConcurrentSingleUseAndPurge`; expired access/refresh rows removed, usable exact-successor recovery retained |

The browser API test originally failed because its shared cookie helper filters
out deletion cookies. Inspecting all Set-Cookie values fixed the assertion;
the fresh-preparation retry passes. An early migration draft used the wrong
formatting job name; the integration gate caught it and the migration now
retains the existing `audio_transcript_formatting` type.

Native/browser UI is not run: E/F/G own client UI acceptance. iOS checks run in
CI. The HTTP harness uses `EMAIL_DELIVERY=log`; a code-reading route is defined
only in `_test.go` and cannot compile into the shipped server. Resend/HIBP are
fake transports; real delivery and the production proxy chain are not tested.
No Resend key was sought. No production configuration or data was read.

Limits to original release acceptance: configure and verify client-IP sources, a verified
Resend sender, owner exemption and client reauthentication inputs before public
signup. These are rollout tasks, not claimed production verification.

## Final validation

Runtime source: `8a2d96a`, based on pipeline plus agent-access merge `ac8ac9d`.
The final commit adds evidence and scoped-key assertions to the existing HTTP
quota scenario; that scenario was rerun with `-race` and passed (6.7 seconds).
No runtime code changed after the full gate.

- **Passed:** Go 1.25.6 arm64 `go vet ./...` and `go test -p 1 -race -timeout 5m -v ./...`, against local PostgreSQL 16 over TCP, database `mta_test_auth`.
- **Passed:** server build; binary byte inspection confirmed `/__test/email-code` is absent.
- **Passed:** gofmt (no unformatted files), `git diff --check`, OpenAPI YAML parse (95 paths) and route inventory test.
- **Passed:** frontend `npm ci`, lint, 38 tests, production build, and production audit (no high/critical production findings). No frontend source changes.
- **Passed:** `scripts/scan-secrets.sh`, committed history and working tree; no findings.
- **Not run locally:** iOS/Android builds and client UI; CI and E/F/G own those checks. No production deployment or real delivery was attempted.

An initial gate overlapped `npm ci`, which removed a Go source inside the
`flatted` dependency while Go enumerated packages. Validation was rerun after
the frontend gate with its generated dependencies removed. A host Go 1.26.2 /
Unix-socket run also stalled in an existing migration preflight and was stopped;
the accepted run uses the repository's Go 1.25.6 and TCP. No shared PostgreSQL
process was stopped.

Task-owned HTTP listeners and worker processes exited; lifecycle cleanup/status
showed no active owned resources. Generated frontend dependencies/build output
and scratch Go build output were removed. The branch/worktree and the dedicated
local test database remain available for the lead's review.


## Independent-review fix pass (2026-11-04)

Implementation branch `v1-auth-fixes` tracks `origin/codex/v1-auth-backend` at
`9c5f751`. Fetched main is an ancestor (no rebase needed). Source brief: the
current v1 plan's Ground rules and D, repository AGENTS.md, AUTH_API.md, and the
prior ledger above. The supplied review decisions supersede the plan's older
signup-password timing and per-challenge-only limits. Scope is backend auth,
quotas, signed proxy routing and their public contract; E/F/G own client UI.
Execution owner: implementation agent. Fixtures: synthetic accounts in local
PostgreSQL 16 `mta_test_auth`, fake email/HIBP/AI transports and loopback HTTP.
No production config or data, real email, or paid AI provider is used.

Required acceptance:

| Case | Expected outcome | Regression evidence |
| --- | --- | --- |
| R1 | Ten wrong codes and five sends per email/purpose in rolling 24h; increasing resend delay; replacement/purge/concurrency cannot reset budget | `TestEmailRollingBudgetsSurviveChallengeReplacement`, `TestEmailSendCapIncreasingDelayAndConcurrency` |
| R2 | Paid malformed chat stays charged; every model input is allowlisted; formatting/manual+automatic/title/summary use shared cap; capped enrichment skips without failing transcription; no capped formatting requeue | `TestAuthHTTPPaidMalformedChatStaysChargedAndModelsAreRestricted`, `TestAuthHTTPOwnerModelBypassUsesExactIdentity`, `TestProviderCallTrackerSurvivesMalformedOutput`, `TestFormattingJobsChargeCapAndCannotRequeueWhenCapped`, `TestAutomaticEnrichmentChecksCapBeforeProvider`, `TestAutomaticUsageInitializesMissingPolicyAndExactOwner` |
| R3 | Only owner user ID or exact key ID exempts account/model policy; prefix collisions do not | `TestUsageExemptionRequiresExactOwnerIdentity`, `TestAuthHTTPOwnerModelBypassUsesExactIdentity` |
| R4 | Unused successor permits lost-response recovery; reuse after successor consumption revokes native and cookie sessions | `TestRefreshReuseAfterSuccessorConsumptionRevokesBothClientFlows`, `TestFirstPartyRefreshRecoversLostResponse`, `TestAuthHTTPBrowserLostRefreshResponseThenReuse` |
| R5 | Signup stores no password before proof; code-holder supplies password on verify; attacker's initiation password cannot become a credential | `TestAuthHTTPSignupPasswordBelongsToEmailProver` |
| R6 | Reset/email change atomically revoke classic, scoped and capture keys and sessions, with notice; ordinary password change preserves keys; account deletion removes keys | `TestAuthHTTPRecoveryRevokesClassicScopedAndCaptureKeysOnlyOnRecovery`, `TestRecoveryKeyRevocationSharesProofTransaction` |
| R7 | Attacking one email cannot exhaust a shared proxy bucket; direct Render trust is opt-in; signed Netlify source validates signature/algorithm/issuer/expiry; unset secret fails safe | `TestAuthHTTPAccountLimitsDoNotShareProxyBucket`, `TestVerifiedProxyClientIPAndFailSafeDefaults`, `TestUnverifiedSharedProxyNeverExhaustsGlobalAuthBucket` |
| R8 | Unverified passwordless session cannot add first password; verified stored email can; forgot password still proves ownership | `TestAuthHTTPFirstPasswordRequiresVerifiedStoredEmail`, `TestAuthHTTPPasswordlessResetChangesAndDeletion` |

Regression sensitivity: **14/14 detected**. Temporarily removed each enforcement
in isolation and ran its named regression test: rolling guesses, daily sends,
paid-parse refund rule, model allowlist, exact-owner policy, refresh reuse,
proof-time signup password, recovery key revocation, signed proxy verification,
shared-IP fallback, first-password proof, formatting charge, formatting requeue
cap and enrichment skip. Each failed behaviorally (no compilation failures),
and every source file was restored before the full gate.

The first fixture run caught two test-data errors (an undersized synthetic hash
and an overlong synthetic key prefix); corrected fixtures pass. It also caught
an implementation boundary mistake: the first-password proof check initially
reached passwordless account deletion. The check now lives only in SetPassword;
existing deletion acceptance was rerun. The formatting fake now returns its
required JSON text envelope.

Compatibility: checked iOS, web and CLI at current main. iOS sends nil model;
web defaults to no override and its documented GPT-4o remains allowed; CLI's
empty default works and arbitrary explicit models are restricted except for the
owner. Build 13's persisted next_refresh_token retry and browser pending-cookie
recovery are tested. Main has account-owned capture keys, with no separate
session-key association or deleted-session key cleanup. Recovery deactivates all
of those keys; account-deletion cleanup is tested for every key type.

Migration 059 is additive and leaves strict SELECT * user/API-key structs alone.
It adds durable email-limit history, clears pending signup hashes, and allows
`skipped` summary/formatting status. Defaults keep public signup and Render
header trust off. Netlify API and SPA catch-all rules move to TOML because
_redirects runs first; domain/SEO behavior remains in _redirects.

Proxy research: [Render documents overwritten CF-Connecting-IP and the spoofing
risk of leftmost X-Forwarded-For](https://render.com/articles/host-pocketbase-on-render).
[Netlify documents HS256 X-Nf-Sign with issuer and expiry and Runtime-scoped
signed redirect secrets](https://docs.netlify.com/manage/routing/redirects/rewrites-proxies/).
Only the documented public Render topology may enable the Render flag. Local
cryptographic/header tests do not establish production edge acceptance.

### Final validation of the review fixes

Runtime/code source: `780fa522582f20e467de41cfa3e7701ced52b5b3`. The following
commit changes this QA ledger only. Required review-fix acceptance: **8/8 passed**.
Final local HTTP repeat: **13/13 TestAuthHTTP scenarios passed**, through full Gin
routes on ephemeral loopback listeners, including persisted account/key/session/
quota outcomes. The last HTTP run took 16.8 seconds. All original affected auth
scenarios were repeated alongside the new ones.

- **Passed:** focused PostgreSQL, middleware, HTTP, summary and worker tests.
- **Passed:** gofmt and git diff --check; Go 1.25.6 arm64 `go vet ./...` and
  `go test -p 1 -race -timeout 5m ./...` with the dedicated local database.
  The router package took 160.5 seconds under race instrumentation; no race or
  acceptance failures remained.
- **Passed:** frontend npm ci, lint, 38 tests and production build. Production
  dependency audit found no high/critical findings. The unchanged development
  dependency tree reports two critical and thirteen moderate npm findings;
  no dependency updates are part of this auth fix pass.
- **Passed:** scripts/scan-secrets.sh over committed history and working tree;
  no findings. OpenAPI YAML parsed (95 paths), signup payload assertions and
  Netlify TOML/redirect-precedence assertions passed.
- **Passed:** compiled release-mode server against local mta_test_auth, with a
  clean environment and ephemeral local credentials: health 200, signup default
  off (403), unknown forgot-password generic 202, and the required startup warning
  when no client-IP source is configured. Binary inspection confirmed the
  test-only email-code route is absent. The first startup attempt lacked the
  repository-required admin credential; the local smoke environment was corrected
  with an ephemeral credential, without reading any production configuration.
- **Not run here:** native/web UI acceptance, local iOS/Android builds, live
  Resend delivery, paid AI calls, actual Netlify signing or production Render edge
  behavior. CI and E/F/G retain platform acceptance; the lead verifies edge trust
  and delivery before enabling public signup. No production deployment occurred.

Production setting names for the lead (no secrets or production values inspected):
`RENDER_CLIENT_IP_ENABLED`, `NETLIFY_PROXY_SIGNATURE_SECRET`, `EMAIL_DELIVERY`,
`RESEND_API_KEY`, `RESEND_FROM_EMAIL`, `PUBLIC_SIGNUP_ENABLED`,
`FIRST_PARTY_AUTH_ENABLED`, `FIRST_PARTY_PASSWORD_AUTH_ENABLED`,
`OWNER_USER_ID` or `OWNER_API_KEY_ID`. The Netlify signature secret needs the
Runtime scope as documented in AUTH_API.md; never expose it through VITE_*.

Owned HTTP listeners, the compiled-server process, workers and test processes
exited. Lifecycle cleanup/status reports **no active owned resources**. Shared
PostgreSQL, other apps' simulators and baseline services stayed untouched.
Generated frontend dependencies/build output were moved to Trash; the local
binary and task scratch files were removed after verification. The dedicated
test database and clean v1-auth-fixes worktree remain for the lead/reviewer.

Implementation is pushed to codex/v1-auth-backend. This pass does not merge,
request a duplicate review, or wait on CodeRabbit. The independent final-head
review and remote CI are separate from the local evidence above.

### PR 102 second review fixes (2026-11-04)

Context: branch based on origin/main ac8ac9d; auth backend for existing and
public-signup accounts, with Clerk still active. Acceptance is agent-executed
local PostgreSQL/API testing on mta_test_auth with synthetic providers. No
production configuration or data was read or changed.

- Recovered workers initialize missing policies before paid work. Configured
  owner exemptions remain supported; unconfigured recovery preserves existing
  policy overrides and exemptions. Unknown duration fails closed for capped users.
- AI refunds use the month returned by the reservation transaction. Failed
  provisional resources refund every recorded month. Failed-to-pending retries
  reserve admission in the same database transaction.
- Completed transcript reuse and upload completion replays reach the handlers;
  database admission still caps new work. Batch admission remains atomic.
- Password onboarding requires password auth enabled. Malformed quota settings
  fail startup. Rejected multipart admission removes its local file. Audit and
  refund failures are logged; refunds are not retried.
- Summary budget is reserved before the optional title. A title hitting the cap
  is skipped. Worker metadata duration reservations are retained instead of
  being replaced by the truncated integer display duration; extractors without
  the guard retain result-duration accounting.
- Go's CSP includes Clerk, Turnstile, workers, Fontshare, Google fonts, and
  embedded YouTube. Netlify serves production HTML, so Go headers do not apply
  to those pages. frontend/public/_headers adds the policy in report-only mode.
  Browser/provider compatibility and deployed response headers remain unverified;
  workstream E should verify before enforcing the Netlify policy.
- OpenAPI initiation/completion status codes match the handlers. Email delivery
  documents that a provider send already started may finish after invalidation.
- The background_jobs CHECK is added NOT VALID to avoid the startup scan.
  Existing rows are not validated by this migration; new writes are checked.
- Declined concurrent expiry indexes as instructed: tables are tiny and the
  migration runner runs inside transactions. No other requested finding declined.

Focused regression coverage includes missing-policy failure, preserved owner
exemption, previous-month provisional refunds, atomic retry rejection, password
onboarding flag, malformed settings, CSP sources, and HTTP completed reuse at
cap versus new-work rejection. Web UI and native device journeys were not run:
this pass changes backend behavior and report-only hosting headers, with no UI
interaction changes. No deployment or merge is authorized in this pass.

Verification: gofmt and diff checks, go vet ./..., the full serialized Go race
suite with TEST_DATABASE_URL pointing only to mta_test_auth, frontend lint,
38 frontend tests, frontend production build, and scripts/scan-secrets.sh passed.
Affected database/worker/handler race tests were repeated after final fixes.
The updated migration 058 functions were refreshed in the existing local test
database before testing; the NOT VALID constraint was checked in a rolled-back
local transaction. No server, browser tab, simulator, or container is left running.
CodeRabbit's earlier review is not approval of these changes; final-head CI and
incremental review remain pending after push.
