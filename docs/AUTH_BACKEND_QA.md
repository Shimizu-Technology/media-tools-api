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

Focused acceptance: **10/10 passed**. Backend and frontend gates passed.
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

Limits to release acceptance: configure and verify proxy CIDRs, a verified
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
