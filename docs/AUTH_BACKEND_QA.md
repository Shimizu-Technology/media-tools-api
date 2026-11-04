# Auth backend acceptance

Workstream D, agent-executed backend QA. Base: origin/main `0fc219e`, 2026-11-04.
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

Run status: preparation. Native/browser UI is out of scope; client UI acceptance
belongs to E/F/G. iOS checks run in CI. Local email delivery is log only; codes
are observed only by a Go `_test.go` HTTP harness, absent from shipped binaries.
