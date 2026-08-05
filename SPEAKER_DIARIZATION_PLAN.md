# Speaker Diarization Product and Implementation Plan

**Status:** Proposed; benchmark before selecting a production provider

**Research date:** August 4, 2026

**Related roadmap item:** [Speaker Labels and Diarization](PRODUCT_ROADMAP.md#9-speaker-labels-and-diarization)

## Decision Summary

Media Tools should add speaker-aware transcription. It is a natural extension of the product's meeting, phone-call, interview, summary, action-item, and evidence workflows.

The feature should be described as **speaker-aware transcription with correction**, not infallible identification. The first release should detect anonymous speakers, let the user rename them, and preserve timestamped playback for verification. Reusable voice identification should be a later, opt-in capability with explicit consent and retention controls.

Before selecting a vendor, run a blind comparison using representative Media Tools recordings. The initial shortlist is:

1. ElevenLabs Scribe v2 for long-file support, word-level speaker labels, and cost.
2. OpenAI `gpt-4o-transcribe-diarize` for the smallest vendor and privacy-boundary change.
3. AssemblyAI for a meeting-focused independent alternative.

If results are close, prefer OpenAI to avoid adding another data processor. If ElevenLabs materially reduces correction time on long meetings, its large-file support and pricing justify the additional vendor.

## Why This Belongs in Media Tools

Media Tools began as a YouTube transcript and summarization API. It is now a private, authenticated media workspace that processes video URLs, recordings, uploads, and PDFs; saves them in a unified library; and supports summaries, chat, collections, evidence, exports, API keys, and webhooks.

Speaker awareness advances the product from "what was said" to "who said what." That enables:

- Meeting transcripts that are easier to scan.
- Action items attributed to the correct participant.
- Decisions, questions, and commitments grouped by speaker.
- Speaker-specific search, summaries, chat, and exports.
- Better future Zoom and multichannel ingestion.
- A reusable meeting-intelligence capability for Shimizu workflows.

## Terminology

- **Transcription:** Converts speech to text.
- **Speaker diarization:** Determines which anonymous voice spoke during each time range.
- **Speaker identification:** Connects a voice to a real person.
- **Speaker turn:** A continuous time range assigned to one speaker.
- **Multichannel transcription:** Uses separate audio channels or participant tracks instead of inferring speakers from one mixed track.

Diarization normally yields labels such as `Speaker 1` and `Speaker 2`. It does not reliably know real names without platform metadata, reference audio, or user input.

## Current Architecture

The audio pipeline currently:

1. Accepts browser/iOS recordings and audio or video uploads.
2. Creates an audio record and durable background job.
3. Retains the original recording in S3 when configured.
4. Uses ffmpeg to normalize and compress the recording.
5. Sends the recording to OpenAI Whisper.
6. Sanitizes repeated or hallucinated Whisper output.
7. Saves the completed transcript and timestamped `media_segments` atomically.
8. Uses those segments for playback, citations, summaries, chat, and exports.

This is a strong foundation because timed segments already exist. However:

- `media_segments` has no speaker relationship.
- `audio_transcriptions` has no speaker or diarization metadata.
- Web and iOS API models have no speaker fields.
- The transcript viewer supports full and timestamped views, but not speaker turns.
- The transcriber is coupled to Whisper's `verbose_json` response and quality fields.

### Critical Long-Recording Constraint

The current recovery path splits every recording of 90 seconds or longer into independent 60-second transcription requests. That prevents long-silence Whisper failures, but independent diarization chunks cannot be concatenated safely: `Speaker 0` may represent a different person in every request.

A production diarization path must either:

- Let one provider see the complete recording and perform global diarization, or
- Run a global speaker-reconciliation stage across all chunks.

Do not add diarization by changing only the model name in the current Whisper request.

## Quality Expectations

Quality depends more on recording conditions than on a provider's headline accuracy.

| Recording | Realistic expectation |
| --- | --- |
| Clean two-person Zoom, phone call, or podcast | Usually highly usable; occasional corrections |
| Clear three-to-six-person meeting | Useful, with corrections around short turns and interruptions |
| Same-room phone/table microphone | Variable depending on distance, echo, and room noise |
| Overlapping speech, similar voices, far-field microphone | Meaningfully less reliable |
| Real-name identification | Less dependable and more sensitive than anonymous clustering |

There is no honest universal accuracy percentage. Public diarization benchmarks vary dramatically by equipment, domain, overlap, and dataset. Product evaluation should emphasize **manual correction minutes per recording** and **action-item owner accuracy**, not only diarization error rate.

High-stakes attribution should always retain timestamped playback and require human review.

## Provider Shortlist

Prices are public prices observed on August 4, 2026 and must be rechecked before implementation.

| Provider | Relevant capabilities | Published price and fit |
| --- | --- | --- |
| OpenAI `gpt-4o-transcribe-diarize` | Speaker segments, timestamps, optional reference clips for up to four known speakers | Token-priced. Smallest vendor change, but its 25 MB request boundary and different response shape require a separate pipeline. |
| ElevenLabs Scribe v2 | Word timestamps, diarization for up to 32 speakers, speaker-count hints, optional speaker library, files up to 3 GB/10 hours | About $0.22/hour. Strongest practical long-recording fit for the current 2 GB upload design. |
| AssemblyAI | Speaker utterances, speaker-count/range hints, separate speaker-identification capability | About $0.21/hour plus approximately $0.02/hour for diarization on the referenced tier. |
| Deepgram | Word-level speaker labels and speaker confidence, batch and streaming support | Roughly $0.468/hour for Nova plus diarization at observed pay-as-you-go rates. Useful alternate benchmark. |
| pyannote | Specialist diarization, overlap handling, speaker-count control, voiceprints, hosted and self-hosted options | Hosted diarization begins around EUR 0.035/hour for Community-1 and EUR 0.112/hour for Precision-2, before transcription. More operationally complex. |

### Research Sources

- [OpenAI speaker diarization guide](https://developers.openai.com/api/docs/guides/speech-to-text#speaker-diarization)
- [OpenAI speaker-aware meeting intelligence](https://developers.openai.com/cookbook/examples/audio/speaker_aware_meeting_intelligence/speaker_aware_meeting_intelligence)
- [OpenAI diarization model](https://developers.openai.com/api/docs/models/gpt-4o-transcribe-diarize)
- [ElevenLabs speech-to-text documentation](https://elevenlabs.io/docs/overview/capabilities/speech-to-text)
- [ElevenLabs speech-to-text pricing](https://elevenlabs.io/pricing/api?price.section=speech_to_text)
- [AssemblyAI speaker labels](https://www.assemblyai.com/docs/pre-recorded-audio/label-speakers)
- [AssemblyAI pricing](https://www.assemblyai.com/pricing/)
- [Deepgram diarization](https://developers.deepgram.com/docs/diarization)
- [Deepgram pricing](https://deepgram.com/pricing)
- [pyannote models](https://docs.pyannote.ai/models)
- [pyannote pricing](https://www.pyannote.ai/pricing)
- [pyannote open model benchmarks](https://huggingface.co/pyannote/speaker-diarization-3.1)

## Product Patterns to Follow

Otter, Descript, Fireflies, and Zoom all pair automatic speaker detection with human correction. Their common pattern is:

1. Detect anonymous speakers.
2. Ask the user to name them.
3. Apply a rename throughout the conversation.
4. Allow correction when a turn is assigned incorrectly.
5. Preserve timestamps and audio playback.

Source metadata should outrank acoustic inference. The preferred source order is:

1. Named participant tracks or a platform-provided transcript/VTT.
2. Separate audio channels.
3. Acoustic diarization from a mixed recording.
4. User rename and correction.
5. Optional, consented voice-reference matching.

References:

- [Otter speaker management](https://help.otter.ai/hc/en-us/articles/40586357592471-Speaker-Management)
- [Descript speaker detection](https://help.descript.com/hc/en-us/articles/10249423506061-Detect-and-label-speakers-in-your-transcript)
- [Fireflies speaker labels](https://guide.fireflies.ai/articles/1234873612-how-to-edit-speaker-labels-in-uploaded-files)
- [Zoom audio transcripts](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0064927)
- [Zoom separate participant tracks](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0064394)

## Recommended Data Model

Create an `audio_speakers` table:

- `id`
- `audio_transcription_id`
- `provider_key` such as `speaker_0`
- `display_name`, initially `Speaker 1`
- `identification_source`: `automatic`, `manual`, `reference`, or `channel`
- Optional confidence
- Stable display color/index
- Created and updated timestamps

Add a nullable `speaker_id` foreign key to `media_segments`.

Add diarization metadata to `audio_transcriptions` or a related processing record:

- Requested/enabled
- Status
- Provider
- Model and version
- Detected speaker count
- Failure/warning metadata

Keep the existing clean `transcript_text` for compatibility. Speaker-aware UI, exports, summaries, and chat context should be rendered from structured segments rather than baking mutable speaker names into the plain transcript.

## Recommended Service Boundary

Replace the Whisper-shaped dependency with an interface defined where the worker consumes it. A normalized result should include:

```text
TranscriptionResult
  text
  language
  duration
  provider/model metadata
  segments[]
    start
    end
    text
    optional speaker key
    optional confidence
```

Provider adapters should own request and response differences. Quality validation must also be provider-aware: retain the current Whisper confidence/hallucination checks for `whisper-1`, and use generic empty/repetition checks plus provider-specific confidence data elsewhere.

## API Direction

The existing segment response should include an optional speaker object or speaker ID. Add endpoints equivalent to:

- `GET /api/v1/audio/transcriptions/:id/speakers`
- `PATCH /api/v1/audio/transcriptions/:id/speakers/:speakerId` to rename globally
- A later segment-reassignment endpoint for correction
- A later re-diarization endpoint for saved S3 audio

Exports should support anonymous or user-assigned speaker names without breaking existing plain-text clients.

## Web and iOS Experience

Add a third transcript mode alongside Full and Timestamped:

- **Speakers:** Consecutive turns grouped by speaker, with timestamp, colored badge, and playback.

Required first-release interactions:

- Rename `Speaker 1` once and update all its turns.
- Filter or focus the transcript by speaker.
- Copy/export speaker-aware text.
- Preserve original timestamps and evidence citations.
- Use assigned speaker names in summaries and action items only when available.
- Clearly label anonymous speakers; do not guess names in the UI.

Enable diarization by default for meetings, phone calls, and interviews. Make it optional or off by default for voice memos and lectures.

## Privacy and Security Boundary

Media Tools is an authenticated private workspace, but processing is not currently on-device. Audio can pass through S3 and a transcription provider, and transcript material can pass through OpenRouter for summaries or chat.

Reusable voice references are biometric-adjacent data. If added later, require:

- Explicit participant consent.
- Documented provider retention behavior.
- Separate deletion of reference audio and transcripts.
- Encryption and strict access control.
- Auditability appropriate to the use case.
- Human verification before consequential attribution.

Do not use the existing cloud pipeline for client material whose policy or regulatory boundary prohibits these processors.

## Benchmark Plan

Build a provider-neutral benchmark before production integration. Use approximately 10-15 hours across 20-30 representative recordings:

- Two-person Zoom and phone calls.
- Three-to-six-person same-room meetings.
- Browser and iPhone recordings.
- Quiet and noisy rooms.
- Overlapping speech and short interjections.
- Similar voices where available.
- Long meetings over 60-90 minutes.
- Local names, accents, code-switching, and realistic Guam vocabulary.

Measure:

- Word error rate.
- Diarization error rate.
- Who-spoke-which-words error or cpWER/WDER.
- Speaker-count accuracy.
- Action-item owner accuracy.
- Manual correction minutes per recording.
- Processing latency and failure rate.
- Effective cost per successful hour.
- Summary quality before and after speaker correction.

Store normalized provider output for inspection, but do not expose benchmark data containing sensitive recordings outside the approved project boundary.

## Delivery Phases

### Phase 0: Benchmark

- Build normalized adapters or a standalone harness.
- Run the selected corpus through OpenAI, ElevenLabs, and AssemblyAI.
- Compare correction effort, cost, long-file handling, and downstream summaries.
- Record a provider decision with evidence.

### Phase 1: Anonymous Speaker Beta

- Add speaker schema and migration.
- Add the provider abstraction and selected adapter.
- Process new meeting/call/interview recordings with diarization.
- Show grouped anonymous speaker turns in the web app.
- Support global speaker rename and speaker-aware export.
- Preserve the current non-diarized path as a fallback.

### Phase 2: Correction and Native Support

- Add turn reassignment and split/merge correction.
- Add speaker filtering.
- Add the complete iOS experience.
- Make summaries, action items, decisions, and chat speaker-aware.
- Allow re-diarization of retained S3 recordings.

### Phase 3: Source-Aware Identity

- Ingest Zoom transcripts/VTT and participant tracks.
- Support multichannel identity.
- Consider opt-in reusable speaker profiles.
- Add team/workspace-level speaker management only after consent and access rules are defined.

## Acceptance Principles

The feature is ready to graduate from beta when:

- Clean two-person calls require little correction.
- Multi-person meetings remain useful even when corrections are needed.
- Users can correct every visible attribution mistake.
- Speaker-aware action items retain timestamp evidence.
- Independent chunk labels can never be silently combined as if globally consistent.
- Provider failures fall back safely or produce a clear retryable state.
- Privacy copy accurately describes every processor involved.

## Explicit Non-Goals for the First Release

- Court-, compliance-, or evidence-grade identity guarantees.
- Automatic real-name guessing from conversational context.
- Persistent voiceprints without explicit consent.
- Self-hosting a diarization model before the hosted-provider benchmark demonstrates a need.
- Retrofitting every historic recording before the new-recording workflow is stable.
