# Waveforms, library rows and backfills

Backend slice for the Sunrise Home / Studio Library redesign. Source contract:
`docs/plans/v1-design-plan.md` on `origin/claude/v1-design-plan`, updated in
`720b8e7`. Implementation starts at main `8304e29` (2026-11-05).

Leon captures recordings and shared Voice Memos on his phone and reads their
transcripts and summaries across iOS, Android, web and `mta`. The new clients need
real waveform data and useful library previews without changing shipped clients.
Go/Gin owns the API, Postgres owns durable jobs, S3 stores audio, and the existing
automatic enrichment worker owns provider calls, preferences and quota accounting.
Production was not accessed for this work.

## API additions

- Library items add optional `excerpt` (at most 200 Unicode characters, plain text,
  ending at a word boundary), optional audio `waveform` (32 integers, 0–100), and
  `collections` (always an array, oldest collection first, with id/name/color).
- Audio detail adds optional `waveform` (200 integers, 0–100). Missing/failed
  waveforms are omitted, so clients show their type icon. Silence is 200 zeroes.
- Collections add `color`: coral, teal, violet, amber, blue or rose. Migration 060
  assigns existing collections in creation order. New collections take the
  account's least-used color, with palette order breaking ties. An account lock
  serializes concurrent allocation. Existing request bodies remain valid.
- `mta items list/search --output json` preserves these additions; existing text
  columns and commands retain their format.

Library text is read with SQL `left(...,4096)` after pagination, then cleaned in
Go. Unspaced/CJK text is cut at a rune boundary if no word boundary fits. Literal
underscores, comparisons and leading four-digit years are preserved; markdown
fences, labels, rules and table separators are removed. A JSON escape cut by SQL
drops only its incomplete tail and keeps the summary prefix. A malformed waveform
is logged and omitted for that row, leaving the rest of the page available. Legacy structured summary JSON is unwrapped before markdown, HTML and citation
markers are removed. Audio and video prefer summaries; PDFs use extracted text.
Collection badges use exactly the same user/key ownership predicate as `GET /collections` and are fetched within the page query, not by per-row API/DB calls.
The page query was measured with 10,000 generated audio rows and long transcripts:
13.876 ms execution in simple mode; 14.964 ms in prepared mode (planning 8.641 ms and
5.114 ms respectively on the shared local Mac). These are local measurements,
not production latency promises. `TestLibraryLargePageExplain` exercises the
actual query with `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`.

## Waveform computation and resource budget

A completed transcription with stored S3 audio (`audio_s3_status=uploaded`) queues `audio_waveform` in its
completion transaction. No AI provider, consent prompt or usage charge is involved.
S3 downloads use streaming `io.Copy` to an owned temporary file. This makes MOV/QTA
containers with trailing metadata seekable without retaining the file in RAM.
ffmpeg emits mono, signed 16-bit PCM at 8 kHz through a pipe with one decoder
thread. Go holds one 100 ms frame (1,600 bytes), writes its absolute maximum as two
bytes to a scratch file, then max-pools those measured frames into 200 equal time
ranges. A two-hour recording needs about 144 KB for that peak spool. The downloaded
source also occupies temporary disk space and is removed when the job finishes.

For each raw 200-bin peak `p`, let `M` be the largest measured absolute sample:

```
waveform[i] = round(100 * sqrt(p[i] / max(M, 327.68)))
```

The denominator has a −40 dBFS floor on the signed-16-bit scale. Square-root
compression lifts quiet speech while preserving relative measured amplitudes;
silence stays zero. Library rows max-pool overlapping time ranges from those 200
stored values into 32. Every response then stretches each recording's own nonzero range to
12 through 100 (`waveform.Stretch`), because speech at this scale sits near the top:
on production's 117 recordings, 25% of 32-bar rows were nearly flat before this and
none after. The order of values never changes, and stored peaks are untouched. The 100 ms source-frame resolution is explicit; timestamps
and signal shapes are never invented.

Measured locally on a generated two-hour PCM MOV with alternating silence/tone:
1.32–1.46 seconds for decode/reduction; 34,552–34,568 bytes total Go allocation;
6.28 MiB peak sampled Go RSS, 20.58 MiB peak child RSS, and 26.08 MiB peak sampled
combined RSS (20 ms sampling over fixture generation and computation). The separate
`/usr/bin/time -l` run reported 20.72 MiB maximum RSS. This measures the waveform
pipeline, not a production server with concurrent Whisper/AI work or S3 latency.
The long test enforces less than 8 MiB total Go allocation.

Reproduce the long allocation/timing check:

```sh
go test -c ./internal/services/waveform -o /tmp/mta-waveform.test
MTA_WAVEFORM_LONG=1 /usr/bin/time -l /tmp/mta-waveform.test \
  -test.v -test.run TestLongStreamingMemory
```

All waveform errors retry at most three attempts, including corrupt media. Final
failure clears only waveform data/status, leaving the recording, transcript and
summary untouched. Ordinary generated-media tests cover silence, a QTA-named MOV
with trailing metadata, corrupt input and cancellation. Worker tests also exercise
a streamed synthetic S3 response through the real decoder and durable completion.

## Admin requests and progress

Use the existing server admin secret in `X-Admin-Key`. Neither route accepts an
`X-API-Key` or `Authorization` header, even alongside a valid admin key. The scoped
agent route classification includes `/admin/` as forbidden. Do not put secrets
literally in shell history, files or PR comments. The following examples assume the
lead has already populated shell variables securely; they print responses only.

Preview all accounts' eligible stored-audio waveforms (no writes, no run id):

```sh
curl --fail-with-body -sS "$API_BASE/api/v1/admin/backfills" \
  -H "X-Admin-Key: $ADMIN_API_KEY" -H 'Content-Type: application/json' \
  --data '{"kind":"waveforms","dry_run":true}'
```

Queue the real waveform run, which returns HTTP 202 and `id` immediately:

```sh
curl --fail-with-body -sS "$API_BASE/api/v1/admin/backfills" \
  -H "X-Admin-Key: $ADMIN_API_KEY" -H 'Content-Type: application/json' \
  --data '{"kind":"waveforms","dry_run":false}'
```

Preview and run enrichment for the owner account only:

```sh
curl --fail-with-body -sS "$API_BASE/api/v1/admin/backfills" \
  -H "X-Admin-Key: $ADMIN_API_KEY" -H 'Content-Type: application/json' \
  --data "{\"kind\":\"enrichment\",\"user_id\":\"$OWNER_USER_ID\",\"dry_run\":true}"
curl --fail-with-body -sS "$API_BASE/api/v1/admin/backfills" \
  -H "X-Admin-Key: $ADMIN_API_KEY" -H 'Content-Type: application/json' \
  --data "{\"kind\":\"enrichment\",\"user_id\":\"$OWNER_USER_ID\",\"dry_run\":false}"
```

Read the returned run's progress:

```sh
curl --fail-with-body -sS "$API_BASE/api/v1/admin/backfills/$RUN_ID" \
  -H "X-Admin-Key: $ADMIN_API_KEY"
```

Example response:

```json
{"id":"run-uuid","kind":"waveforms","dispatch_status":"completed","queued":4,"running":1,"completed":110,"failed":2}
```

The four counts include only jobs that this run created. The dispatcher, fresh
recordings, earlier queued jobs, and overlapping runs are excluded. The dispatcher
itself is durable and restarts safely. `dispatch_status: completed` means dispatch
has finished; processing finishes when `queued` and `running` are both zero.
A failed dispatcher is reported separately and can leave already-created child
jobs processing. Counts describe job states: an AI job that intentionally skips
for the usage cap completes without creating a summary, so preview enrichment
again before declaring every item enriched. Repeating the POST creates a new run that picks up only remaining
eligible work; it never adopts another run's existing jobs.

Dry runs report `eligible`, `summaries`, `titles`, `title_names`, `protected_titles`
and zero `enqueued`. `title_names` is the exact list of original names selected for
retitling, in source creation order, preserving extensions and Unicode characters.
It is returned only through the admin-protected preview. Unknown enrichment
accounts return `404 account_not_found` on both preview and creation; UUID inputs
are normalized before use. They create neither a run nor usage reservations. In-flight eligible
counts can change between preview and execution. Failed recordings are excluded.
Waveform terminal decode failures stay absent. A pending row with no queued/running
waveform job is eligible again, including a job failed by an older worker during
deploy overlap. A running waveform job can compute from the same stored source
while retranscription is pending/processing, so it does not finish empty and lose
its queue slot when retranscription completes.
An AI job that failed or was quota-skipped can be explicitly resumed in a new run.

## Enrichment ownership and pacing

Enrichment selects completed audio with `audio_transcriptions.user_id` equal to
whichever account the admin passes. Account reads/writes keep main's strict
`user_id` rule; classic API-key reads/writes remain scoped to the exact key. The
lead reported that all 131 production audio rows had a user_id, with no key-only
rows. Earlier visibility widening has been reverted. Row badges likewise expose
only collections returned by that actor's `GET /collections`.

Enrichment queues the existing `audio_summary` worker with `Automatic: true`, the
original title as `TitleSource`, and `TitleOnly` when it already has a summary or
automatic summaries are disabled. It uses the same provider settings and monthly
usage reservation path. Preferences are checked at dispatch and again at execution. The payload carries
the row's real `content_type`, and processing preserves the stored type if an
older payload omitted it. Dispatch leaves `summary_status` unchanged: a queued
backfill does not make a completed Library item appear in progress. The worker
sets processing when it actually runs the summary. Startup recovery inserts only
missing jobs; it never replaces a queued/running job's payload, priority, attempt
budget or run attribution. Disabled title-only work clears any stale pending
summary status. A quota-skipped title-only job fails and remains eligible for an
explicit later run; it is never counted as a finished title.
There is no persisted backend AI-consent record in this codebase; consent is
collected by clients before provider processing. This admin operation reuses the
existing automatic path and requires the lead's explicit account selection.

Titling first removes only a known audio extension, case-insensitively: m4a,
caf, mp3, wav, webm, mp4, mov, qta, ogg, aac, flac, opus, aif, aiff, m4b, mpeg,
mpga or 3gp. A dot within a chosen name is retained. Automatic titling recognizes
bare defaults (`Recording`, `New Recording` plus an optional number, `Voice Memo`
plus an optional number, `Audio` plus an optional number, `Untitled`), UUID file
names, numeric ISO-style recording names, and the app's dated em-dash format.

The em-dash format is exactly `Recording — Mon D, YYYY at H:MM AM/PM`, or a
24-hour `H:MM` without AM/PM. `Mon` is Jan–Dec; the calendar date and clock range
must be valid. Before AM/PM it accepts plain space, U+00A0 or U+202F. Arbitrary
text such as `Mayor interview 2026` cannot occupy the date position.

Normally `title_manually_set` must be false. For an explicit enrichment run on
**any admin-selected user_id**, a row created before `2026-11-05T00:00:00Z` may
have migration 055's blanket flag cleared only when its name matches the narrower
legacy set: Recording, New Recording with optional number, Voice Memo with optional
number, Untitled, UUID, numeric `recording-YYYY-MM-DD` timestamp, or the validated
em-dash date format. Bare `Audio N` and standalone ISO dates do not qualify for
this legacy override. Recent manually flagged rows stay protected. The queue
rechecks the original name under a row lock before clearing the flag. The worker
checks it again and uses a compare-and-swap guarded by the manual-title flag, so a
rename after queueing wins.

`protected_titles` counts generated-looking names blocked by that protection.
`title_names` lets the operator review the exact names that will be eligible.
A person who deliberately typed exactly a default cannot be distinguished from
the old default; the lead accepted this ambiguity for the explicit run. No rename
history is fabricated or inferred for other names.

Old transcripts without timed segments are chunked into persisted, untimed
citation evidence by the existing path. An integration test runs the actual
summary service with a synthetic provider response and verifies its completed
summary and real segment citation with a null timestamp; no new summarizer or
fabricated seek time is introduced.

Fresh recording/transcription, summary and other existing jobs keep priority 0.
New waveform work uses priority 5; backfill dispatch and child jobs use priority 10.
Only one job with positive priority may run across all worker processes, protected
by a short transaction advisory lock while claiming. With production's three
workers, two slots remain available to normal work. Fresh jobs are claimed before
queued maintenance. Sleeping workers ignore blocked maintenance until its lease or
completion signal, avoiding a busy polling loop. Running jobs aren't preempted. Expired maintenance leases are reclaimed before
queued maintenance siblings, while priority-0 work still wins. A blocked expired
maintenance row is excluded from wake timing until the active maintenance lease
expires, preventing an idle-worker polling loop.

## Acceptance and deployment

Agent-executed, affected backend flows use only the dedicated local
`mta_test_server` database on borrowed Postgres at `/tmp`; synthetic audio and
provider responses contain no production data. Required scenarios: transactionally
queued waveform work; stored S3-to-decoder success; silence/corruption/cancellation;
independent bounded failure; library/detail peak lengths, excerpt cleaning and
collection badges; color allocation; dry-run non-mutation; run-specific four-state
progress; agent denial; strict account/key ownership; untimed cited summaries; new-work
priority and a single maintenance slot. Tests cover both database query modes.

Migration 060 adds nullable peaks, status, collection colors, queue priority and
backfill run/job tables. Audio selects remain explicit, avoiding new-column scan
failures. Existing endpoint/request fields are retained. No new environment
variables or external services are required; ffmpeg is already in the runtime.
Deploy the upgraded server and wait for the prior worker instance to drain before
the lead runs backfills. No backfill runs automatically during migration.

The backend credential scan, formatting, vet, race suite and prepared-mode suite
are the local gate. Client UI/device behavior and Render/Neon/S3 production memory,
latency, data counts and provider delivery are not verified here. iOS, Android and
web checks are left to CI and their own slices. The lead owns production dry runs,
backfill execution, release verification, review and merge.

The initial acceptance on `5d8f45e` preceded the material independent review.
The correction evidence below supersedes its ownership, title and recovery claims.

## Review correction evidence

The lead's `96beca4` corrected persisted S3 status to `uploaded` and enabled the
explicit legacy-placeholder override. The follow-up review fixes add regression
coverage for every reported chosen-name probe, U+202F/U+00A0/24-hour dates,
content-type preservation, restart payload/AI-cap behavior, safe deletion ordering,
queued Library status, expired-lease wake timing, capped title retry, text cleanup,
collection scope parity, account waveform-job purge, orphaned waveform resumption,
workspace scans and error reporting, account normalization/existence, storage and
dispatch error propagation, full audio OpenAPI coverage, and retranscription
concurrent with waveform generation. Tests use only task-owned `mta_test_server`.

The complete dry-run response shape is:

```json
{
  "kind": "enrichment",
  "dry_run": true,
  "eligible": 1,
  "summaries": 1,
  "title_names": ["New Recording 42"],
  "titles": 1,
  "protected_titles": 0,
  "enqueued": 0
}
```

For a waveform preview, `kind` is `waveforms`, `eligible` counts eligible audio,
`title_names` is `[]`, and summary/title/protected/enqueued counts are zero. There
is no dry-run id and no write. Real runs still return only `id`, `kind`, and
`dry_run: false` immediately; GET progress counts only their created jobs.

Audio deletion now requires the DB delete to succeed before issuing S3 deletion;
a failed ownership/row check cannot destroy the source. Storage cleanup after a
successful row deletion remains best effort, as before. Workspace uses explicit
audio projections and returns 503 on read failure instead of a false empty list.
Account deletion includes waveform jobs. No migration lock timeout was added;
startup must not be stranded by a dirty migration after a timeout.

Review acceptance is agent-executed against synthetic local fixtures. The following
regressions exercise saved outcomes, including provider/S3 boundaries intercepted
locally; no production data or configuration was read by this implementation run.

| Finding | Fix and regression |
| --- | --- |
| 1–2: chosen titles and Unicode dates | `TestRecordingTitleSafetyRegression` and `TestEnrichmentBackfillRetitlesOnlyOldExactPlaceholders`: all listed chosen names stay unchanged; valid calendar dates, extension allowlist, U+00A0/U+202F and 24-hour names qualify; exact preview names preserved. |
| 3: content type | `TestBackfillDryRunDispatchAndLegacyCitedSummary`: voice_memo remains voice_memo after actual cited-summary processing. Missing payload types retain the stored type. |
| 4: restart payload loss | `TestReviewRecoveryPreservesBackfillAndCappedTitleRetry`: startup leaves Automatic/TitleSource/TitleOnly/content_type/backfill payload and priority intact; the cap prevents provider calls, then a later run can title after quota is restored. |
| 5: ownership and destructive deletion | `TestBackfillStrictOwnershipAndIdempotency` and `TestReviewDeleteNeverRemovesAudioBeforeOwnedRow`: account cannot read/delete key-only audio; classic key access remains; simulated failed DB deletion makes zero storage calls; successful deletion proves the row is gone before storage removal. |
| 6: queued Library status | `TestBackfillDryRunDispatchAndLegacyCitedSummary`: after dispatch the completed Library item remains completed. |
| 7: expired maintenance | `TestReviewExpiredMaintenanceReclaimedBeforeSiblings`: reclaim beats queued siblings; the single maintenance slot and future wake prevent idle polling even with another expired row. |
| 8: capped title retry | `TestReviewRecoveryPreservesBackfillAndCappedTitleRetry`: capped job fails, preview selects it again, and retry succeeds after restoring quota. |
| 9: excerpt cleanup and truncated escapes | `TestExcerptReviewRegressions`: CJK length, snake_case, comparisons, year prefix, rules, tables, fences and partial JSON escapes retain usable text. |
| 10: collection visibility | `TestReviewWorkspaceBadWaveformAndCollectionScopes`: badges/list use the same strict actor scope; key-only collections stay visible to the classic key. |
| 11: inaccurate operator rules | This document and code comments specify the exact old-row override for any admin-selected account, with the accepted identical-default ambiguity. |
| 12: account purge | `TestRequestAccountDeletionPurgesOwnedDataAndQueuesCleanup`: waveform jobs are removed with the account's audio jobs. |
| 13: orphaned pending waveform | `TestReviewOrphanedWaveformPendingIsResumable`: a pending row with an old failed job gets one new live job, without duplicates. |
| 14: workspace scan/error | `TestReviewWorkspaceBadWaveformAndCollectionScopes` and `TestReviewWorkspaceReadFailureReturns503`: manual flag/new peaks no longer break scans; read failure is 503. Source search found no remaining audio SELECT-star projection. |
| Malformed waveform | `TestReviewWorkspaceBadWaveformAndCollectionScopes`: bad stored values are logged and omitted while the page still succeeds. |
| Account UUID/existence | `TestBackfillAdminHTTPAndRunSpecificCounts`: URN UUID normalizes; missing accounts return account_not_found on dry and real paths; dry count snapshots check their errors. |
| Dispatch/download errors | `TestReviewDispatcherStartAndDownloadErrorsRetainRetryCause`: initial DB failure is retryable and the original storage cause survives wrapping. 503 paths log their underlying cause. |
| Disabled title-only status | `TestReviewDisabledTitleOnlyDoesNotRemainPending`: stale pending becomes skipped. |
| Test/schema completeness | `TestReduceMaxPoolsOverlappingRanges`, checked fixture/marshal errors, and `TestAudioDetailSchemaCoversResponseFields` cover deterministic pooling and every public audio model field. |
| Retranscription overlap | `TestStoredAudioWaveformDurableJob`: retranscription completes while an existing waveform job is downloading; the same job then stores 200 real peaks and no queue slot is lost. |

The migration intentionally has no lock timeout. No rename-history reconstruction
was added: old identical default names have no recoverable provenance, and the
explicit admin preview is the accepted control. The earlier key-only ownership
expansion was reverted instead of extending all mutations to a new access rule.

Review validation result (2026-11-05, based on lead commit `96beca4`): all focused
regressions and the complete backend gate passed in both query modes. Executed:

```sh
./scripts/scan-secrets.sh
test -z "$(gofmt -l $(rg --files cmd internal -g '*.go'))"
go vet ./...
TEST_DATABASE_URL='postgres:///mta_test_server?host=/tmp&sslmode=disable' \
  go test -p 1 -race ./...
TEST_DATABASE_URL='postgres:///mta_test_server?host=/tmp&sslmode=disable&default_query_exec_mode=cache_statement' \
  go test -p 1 ./internal/...
```

The two-hour memory test was rerun on the unchanged streaming reducer: 1.506 s
for decode/reduction, 34,552 bytes total Go allocation, 200 peaks, and 26.03 MiB
sampled combined Go/ffmpeg RSS at 20 ms sampling (including fixture generation).
The test's 8 MiB total-allocation bound passed. OpenAPI YAML parsed and the public
audio field coverage test passed. Native builds/UI and production/provider delivery
remain outside this backend-only run; providers and S3 were intercepted locally.
