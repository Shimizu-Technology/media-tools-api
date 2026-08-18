# Media Tools System Overview

## What the product is

Media Tools is a private media-intelligence workspace with three clients: a
React web app, a native SwiftUI iPhone app, and a Go API for automation. It
turns video URLs, recordings, uploaded audio/video, and PDFs into durable,
searchable items that can be summarized, discussed with AI, organized, and
exported.

The app began as a YouTube transcript API and grew because the useful unit was
not “a transcript request”; it was a piece of source material that should stay
available after processing. That is why recordings, PDFs, summaries, chat,
collections, tags, favorites, and processing status now converge in one media
library.

## Primary user loop

1. Capture a source: paste a supported video URL, record or upload a meeting,
   or upload a PDF.
2. Receive a durable media item immediately while processing continues in the
   background.
3. Return through the processing center or unified library; work is not tied to
   the browser tab that started it.
4. Read the transcript or extracted text, play timestamped recording evidence,
   generate a summary, or ask cited questions.
5. Organize the item with collections, tags, favorites, or archive state, then
   copy or export the result.

## How the system connects

```text
React web app ─┐
SwiftUI app ───┼─ HTTPS/JSON ─> Go API ─> PostgreSQL
API clients ───┘                   │
                                  ├─ durable worker queue
                                  ├─ yt-dlp (video metadata/subtitles/audio)
                                  ├─ OpenAI (recording transcription)
                                  ├─ OpenRouter/OpenAI (summary and chat)
                                  └─ S3-compatible storage (durable source audio)
```

The API owns authentication, authorization, media state, processing, and data
integrity. Clients render workflows and may refresh status, but they do not own
the job lifecycle. PostgreSQL stores both media records and durable jobs, so a
server restart does not silently discard accepted work.

## Product surfaces

| Surface | Primary role | Authentication |
|---|---|---|
| React web app | Full workspace, processing center, exports, developer tools | Clerk JWT or local API-key mode |
| SwiftUI iPhone app | Fast capture, recording, library search, details, chat, and collections | Native Clerk session |
| Go API | Media processing and automation | `X-API-Key` or Clerk/legacy bearer token |

The iPhone client is native SwiftUI, not React Native. Share Extension and
Widget source files exist as prototypes, but their targets, entitlements,
signing, and on-device behavior are not part of the shipping app yet.

## Data and ownership model

- Every media item has a concrete type (`youtube`, `audio`, or `pdf`) and ID.
  Clients must keep both values because IDs can overlap across tables.
- Browser/native user work is owned by the signed-in user. Developer work can
  be owned by an API key.
- API keys are stored as hashes; the raw value is returned only at creation.
- The unified library is the cross-media read model for search, pagination,
  filters, status, tags, favorites, and archive state.
- Timestamped/page-based evidence is stored separately so summaries and chat
  can cite the source instead of returning unsupported prose.

## Processing behavior

- Creation endpoints return accepted media records before expensive work is
  complete.
- Workers claim durable jobs from PostgreSQL and heartbeat while processing.
- Recordings may be normalized, compressed, and split before transcription;
  original audio is durable across retries when object storage is configured.
- Retry behavior distinguishes recoverable infrastructure failures from bad
  input and preserves useful status/error details for the clients.
- Webhooks are an API-client completion mechanism; browser/native clients use
  the library and item endpoints to refresh visible state.

## Current product boundaries

- Video ingestion extracts spoken content and metadata; it is not general
  frame-by-frame visual analysis.
- PDF extraction handles text PDFs. OCR-required documents report that state
  rather than pretending extraction succeeded.
- Speaker diarization, team workspaces, semantic search, native offline queues,
  and shipping iOS extensions remain roadmap work.
- The app is designed as a private workspace. Public sharing requires an
  explicit, revocable sharing feature rather than exposing stored media by
  default.

## Where to look in the code

1. `cmd/server/main.go` — dependency wiring, startup, recovery, and shutdown.
2. `internal/router/router.go` — public, authenticated, and admin route groups.
3. `internal/models/models.go` — core API/domain structures.
4. `internal/services/worker/worker.go` — durable job execution and recovery.
5. `internal/middleware/` — API-key and Clerk authentication, CORS, rate limits.
6. `frontend/src/App.tsx` — web routes and app shell.
7. `ios/MediaTools/MediaTools/` — native app, services, and SwiftUI workflows.

Historical plans remain in the repository because they explain how the project
evolved. They are not the source of truth for current behavior; this document,
the root README, the route configuration, and executable tests are.
