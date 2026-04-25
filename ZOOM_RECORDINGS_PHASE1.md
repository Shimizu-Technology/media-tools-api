# Zoom Recordings — Phase 1 Plan

## Goal

Allow Media Tools API to accept Zoom meeting recordings in Phase 1 without creating a separate Zoom-only product surface.

Phase 1 should let users:

- upload Zoom cloud or computer recordings manually
- transcribe the spoken content
- generate AI summaries
- chat against the resulting transcript

This should reuse the existing audio transcription pipeline as much as possible.

## Why This Approach

The current app already has the hard parts of the workflow:

- authenticated upload endpoints
- durable S3-backed source storage
- async worker processing
- ffmpeg-based transcoding and chunking
- transcript storage
- summary generation
- chat over completed transcripts

That means Zoom support is primarily an ingestion and product-boundary decision, not a greenfield feature.

## Decision

Phase 1 will support Zoom recordings through the existing `/api/v1/audio/*` flow.

Specifically:

- accept Zoom `.mp4` meeting recordings in addition to the existing audio formats
- continue accepting Zoom `.m4a` audio-only recordings
- treat video recordings as transcription inputs, not as full video-analysis inputs
- normalize Zoom `.mp4` uploads into audio before sending them to the transcription model

This keeps the product audio-first while still supporting the most common Zoom artifact users already have.

## In Scope

- manual upload of Zoom recording files
- support for `.mp4` in backend validation
- support for `.mp4` in frontend upload validation and file picker
- UI copy updates so the product clearly accepts recordings, not just audio files
- worker normalization so uploaded Zoom videos are processed as audio for transcription
- documentation updates reflecting the new supported format

## Out Of Scope

- Zoom OAuth integration
- automatic import from Zoom cloud recordings
- webhook-driven sync from Zoom
- importing Zoom chat `.txt` files or Zoom transcript `.vtt` files
- speaker-separated transcript storage
- true video understanding of slides, screen shares, or visual meeting context

## Product Boundary

Phase 1 is intentionally not "Zoom integration".

It is "Zoom recording compatibility".

Users bring a Zoom recording file they already have, and the app processes it through the same pipeline used for uploaded audio recordings.

## Why Not Full Video Understanding Yet

For most meeting Q&A use cases, the spoken conversation is the high-value signal.

Full video understanding is a different problem:

- frame extraction
- OCR
- scene or slide segmentation
- multimodal indexing and retrieval
- higher storage and inference cost

That should be treated as a later product phase, not bundled into initial Zoom support.

## Why Not Depend On Zoom's Native Transcript

Zoom can generate transcript artifacts for cloud recordings, but that should remain optional future input, not the main path.

Reasons:

- cloud-only feature
- English-only according to Zoom's support docs
- different accounts have different recording settings enabled
- keeping transcription in our own pipeline yields more consistent behavior

## Technical Notes

### Existing Fit

The existing audio pipeline already provides:

- upload endpoints in `internal/handlers/audio.go`
- worker processing in `internal/services/worker/worker.go`
- transcription API integration in `internal/services/audio/transcriber.go`
- transcript summaries and chat in the existing audio endpoints

### Phase 1 Processing Rule

If the uploaded file is a Zoom `.mp4` recording:

- store it as the original source artifact
- extract/compress audio via ffmpeg before transcription
- continue using the existing transcript, summary, and chat storage model

This avoids sending unnecessary video payloads downstream and keeps behavior aligned with the product's current audio-first design.

## Risks And Tradeoffs

### Pros

- fast to ship
- low schema churn
- reuses proven queue/storage/transcription code
- covers the most common Zoom recording workflow immediately

### Cons

- transcript still represents spoken audio only
- no visual meeting context
- no provider metadata for Zoom-specific imports yet
- no speaker-aware storage in Phase 1

## Follow-On Phases

### Phase 2

Add a real Zoom import integration for signed-in users:

- user-linked Zoom OAuth connection
- least-privilege recording scopes
- import job for cloud recordings
- dedupe on provider recording IDs

### Phase 3

Add optional multimodal meeting analysis:

- slide-aware or screen-share-aware extraction
- OCR and frame sampling
- separate retrieval path for visual context

## Success Criteria For Phase 1

Phase 1 is successful when a user can upload a Zoom `.mp4` or `.m4a` recording and:

- the file is accepted by the frontend and backend
- transcription completes through the existing worker pipeline
- summaries still work
- transcript chat still works
- no new Zoom-specific auth or provider setup is required
