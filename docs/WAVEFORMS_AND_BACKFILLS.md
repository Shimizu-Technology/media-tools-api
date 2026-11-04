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
Go. Legacy structured summary JSON is unwrapped before markdown, HTML and citation
markers are removed. Audio and video prefer summaries; PDFs use extracted text.
Collection badges are fetched within the page query, not by per-row API/DB calls.
The page query was measured with 10,000 generated audio rows and long transcripts:
13.876 ms execution in simple mode; 14.964 ms in prepared mode (planning 8.641 ms and
5.114 ms respectively on the shared local Mac). These are local measurements,
not production latency promises. `TestLibraryLargePageExplain` exercises the
actual query with `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`.

## Waveform computation and resource budget

A completed transcription with stored S3 audio queues `audio_waveform` in its
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
stored values into 32. The 100 ms source-frame resolution is explicit; timestamps
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

Dry runs report `eligible`, `summaries`, `titles`, `protected_titles` and zero
`enqueued`. They create neither a run nor usage reservations. In-flight eligible
counts can change between preview and execution. Failed recordings are excluded.
Waveform terminal failures stay absent and aren't reset by repeating a backfill.
An AI job that failed or was quota-skipped can be explicitly resumed in a new run.

## Enrichment ownership and pacing

An audio item belongs to the requested account when `a.user_id` equals that account,
or when `a.user_id` is null and its API key belongs to that account. The library's
audio list/stats and audio detail use the same fallback; an explicit different
item owner always wins. Classic API-key reads remain exact-key scoped. This covers
older key-only recordings without widening the backfill to another account.

Enrichment queues the existing `audio_summary` worker with `Automatic: true`, the
original title as `TitleSource`, and `TitleOnly` when it already has a summary or
automatic summaries are disabled. It uses the same provider settings and monthly
usage reservation path. Preferences are checked at dispatch and again at execution.
There is no persisted backend AI-consent record in this codebase; consent is
collected by clients before provider processing. This admin operation reuses the
existing automatic path and requires the lead's explicit account selection.

Only generated-looking placeholders with `title_manually_set=false` receive a
`TitleSource`. The worker also checks that the name is still unchanged and
uses a compare-and-swap update guarded by the manual-title flag. Historical names
marked protected by migration 055 remain protected, even if they resemble a
placeholder; `protected_titles` makes that visible in the preview. They cannot be
safely distinguished from a person's deliberately chosen name. No protection flag
is cleared by this migration or backfill.

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
completion signal, avoiding a busy polling loop. Running jobs aren't preempted.

## Acceptance and deployment

Agent-executed, affected backend flows use only the dedicated local
`mta_test_server` database on borrowed Postgres at `/tmp`; synthetic audio and
provider responses contain no production data. Required scenarios: transactionally
queued waveform work; stored S3-to-decoder success; silence/corruption/cancellation;
independent bounded failure; library/detail peak lengths, excerpt cleaning and
collection badges; color allocation; dry-run non-mutation; run-specific four-state
progress; agent denial; legacy key ownership; untimed cited summaries; new-work
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

Local acceptance completed on 2026-11-05 against Go/SQL code commit
`5d8f45ed76465548575ce38237277c4e95709976`; the following amendment changes only
this evidence document. The backend gate passed in full, including the race suite
and prepared statements. The final page-query measurements above ran afterward in
both modes. OpenAPI YAML parsed successfully.

| Required backend scenario | Result |
| --- | --- |
| Stored S3 audio → real ffmpeg → durable 200 peaks; library 32 peaks | Passed |
| Silence, QTA/MOV, corrupt input, cancellation; independent bounded failure | Passed |
| Excerpts, omitted empty fields and collection arrays across audio/video/PDF | Passed |
| Six-color allocation and collection ordering | Passed |
| Dry run writes neither state, jobs, runs nor usage | Passed |
| Immediate durable run id, restart/overlap, four counts isolated from fresh work | Passed |
| Both admin routes reject agent keys; route-scope table stays fail-closed | Passed |
| Legacy key ownership, failed-item exclusion, title protection and opt-out | Passed |
| Legacy untimed transcript produces a completed summary with valid citation | Passed |
| Fresh work ahead of queued backfill and during one running maintenance job | Passed |
| Two-hour bounded-memory decode and 10,000-row query measurement | Passed locally |
| Production, real provider delivery and client/device UI journeys | Not run in this slice |
