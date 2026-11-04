# Workstream C verification

Implementation starts at `origin/main` commit `0fc219e` on branch
`codex/v1-pipeline-reliability`. Scope follows section C of the foundation
release plan. The release-plan ledger is unchanged.

Leon captures recordings and shared media on iPhone and needs processing to
finish without another client action. Existing integrations are Whisper,
OpenRouter, S3, and PostgreSQL; the queue must sleep indefinitely when idle.
The source brief is repository AGENTS.md, the foundation release plan, and the
worker, audio handler, durable queue, and completion transaction at that commit.
Production configuration and production data were not accessed.

## Acceptance evidence

Agent-executed on the local Mac, Go backend and PostgreSQL 16 database
`mta_test_pipeline`. No real provider requests were made.

- Real HTTP: a local HTTP test server runs the actual upload and read handlers
  with the durable worker. Upload a generated AAC-in-MOV file; receive 202;
  poll the real GET endpoint; observe completed transcription, title
  `Tomorrow Morning Call`, summary `Call tomorrow morning.`, and saved
  evidence citing the source segment. The fake Whisper provider returns 503
  first, then succeeds on retry. Test: `TestPipelineHTTPUploadToTitleAndCitedSummary`.
- Resume: process a chunk, reconstruct the pool, process the identical source
  again, and assert exactly one provider call. Checkpoints use source-byte
  hashes and survive process restart. Test: `TestCompletedChunkResumesWithoutProviderCall`.
- Panic: a deliberately missing extractor panics during dispatch; the durable
  job and transcript both end failed. Test: `TestPanickingJobAtomicallyFailsItsItem`.
- Expired lease: exhausting attempts fails the job and item and sets the stage
  to failed. Test: `TestPipelineFailureAndExpiredLeaseAreBounded`.
- Re-transcribe: queue a replacement, fail its durable job, and verify the old
  transcript, summary, and chat remain saved. Test:
  `TestFailedRetranscriptionKeepsPriorResultAndChat`.
- Preferences and rename: disabled summaries queue title-only enrichment;
  a manual rename cannot be replaced by the title update. Test:
  `TestAutomaticSummaryPreferenceAndRenameProtection`.
- Real ffmpeg: generate MOV, transcode it, split MP3 using stream copy, and
  probe all resulting parts and their combined duration. Test:
  `TestMOVTranscodeAndStreamCopySplit`.
- Short speech in a ten-minute recording remains valid. Retry-After accepts
  both seconds and HTTP-date. Existing recovery tests cover inherited leases,
  supervisor restart, renewal, acknowledgement, and no idle polling.

Required commands: gofmt, `go vet ./...`,
`TEST_DATABASE_URL=postgres:///mta_test_pipeline?sslmode=disable go test -p 1 -race ./...`,
and `scripts/scan-secrets.sh`. Backend acceptance uses local provider fakes.
Web, Android, and iOS builds are delegated to repository CI by the task brief;
no native or browser UI acceptance is claimed. Live S3 and provider integration
were not exercised. Temporary HTTP servers and worker goroutines close in test
cleanup; lifecycle cleanup verifies no remaining owned processes.

## Deployment

Apply migration 055 before deploying the new server. It adds checkpoint and
preference tables and a rename-protection flag, preserves old columns and job
payloads, and raises ordinary job attempts to five. Existing historical titles
are conservatively protected. Account deletion retains its existing retry policy.
New durable source payloads omit local paths when S3 exists; old payloads remain
readable and missing local files fall back to S3.

Automatic enrichment is default off at the deployment level. After every worker
instance has upgraded, set `AUTOMATIC_AUDIO_ENRICHMENT_ENABLED=true`. This avoids
older workers ignoring the new title-only payload when summaries are disabled.
The user preference defaults to automatic summaries on. Bearer clients read or
patch `/api/v1/account/processing-preferences` with `automatic_summaries`.
`OPENROUTER_TITLE_MODEL` defaults to `openai/gpt-4o-mini`; summaries
continue through the existing Summarizer evidence and citation path.

Successful replacement transcription invalidates old chat in its completion
transaction; failures preserve the prior saved content. No new recurring idle
poller was introduced. Lease recovery runs through existing active-work wakeups.
Checkpoint rows are deleted with their audio item.

The lead owns CodeRabbit review, CI evaluation, merge, rollout configuration,
and production verification. This workstream does not merge or deploy.
