# Media Tools Product Roadmap

This roadmap captures the direction for Media Tools now that the app has moved from an API demo into a Clerk-authenticated media workspace.

## Product North Star

Media Tools should become a private workspace where every video transcript, recording transcription, PDF extraction, summary, chat, and collection is saved as a searchable media item tied to the signed-in user.

The core product model:

1. Process media from video URLs, recordings, uploads, and PDFs.
2. Save every result into a unified media library.
3. Let users summarize, chat, organize, export, and share those items.
4. Keep API keys and webhooks available for developer/server workflows.

## Current Foundation

Already in place:

- Clerk-first signed-in `/app/*` workspace.
- Public landing page, API docs, and privacy page.
- Video transcript extraction.
- Audio recording/upload transcription.
- PDF text extraction.
- AI summaries and item chat.
- Media library and collections.
- Unified detail pages for video, audio, and PDF items.
- Full-content library search across transcripts, documents, summaries, and tags.
- Starred items, tags, and archive views.
- Processing center for active, failed, and completed jobs.
- User-owned records plus API-key-owned developer workflows.
- Webhooks, exports, and owner/admin operational tools.

## Recently Shipped

### 1. Unified Item Detail Pages

Media items now share a consistent detail route and workspace experience.

The canonical web route is `/app/items/:itemType/:itemId`.

Each detail page includes:

- Main transcript/text/document viewer.
- Summary panel.
- Chat panel.
- Status, retry, and error handling.
- Add to collection action.
- Export and copy actions.
- Metadata such as source, created date, word count, duration/page count, and owner.

Why this matters: it makes video, audio, and PDF results feel like one coherent product instead of separate tools.

### 2. Global Search

The library now searches titles, transcript/document content, summaries, structured audio outputs, and tags from one server-side result set.

Search covers:

- Video transcripts.
- Audio transcriptions.
- PDF text.
- Summaries.
- Collection and chat-history search remain future extensions.

PostgreSQL full-text search and filters are the current foundation. Consider
semantic/vector search later.

Current core filters:

- Type: video, audio, PDF.
- Status: processing, completed, failed.
- Sort direction.

Date range and collection-scoped filtering remain useful follow-up work.

### 3. Better Library Organization

The library now supports starred items, tags, archive, status filters, sorting, collections, and bulk deletion.

Next organization improvements are client/project labels, saved filters, and
broader non-destructive bulk actions. Tags, favorites, archive, deletion, and
type/status/date sorting already ship.

Collections remain useful for grouped work, but tags and favorites make everyday organization faster.

### 4. Processing Center

The processing center now shows queued, active, failed, and recently completed work with automatic refresh and links to recovery actions.

It shows:

- Active jobs.
- Queued jobs.
- Failed jobs.
- Retry buttons.
- Error messages.
- Recently completed items.
- Upload/transcription progress when available.

Why this matters: video/audio/PDF processing can take time, so users need confidence that work is still moving.

### 5. Share and Export Improvements

Copy and several export actions already ship. The next step is to make results
portable without weakening the private-by-default ownership model.

Next additions:

- More consistent `.txt`, `.md`, and `.json` behavior across every media type.
- `.docx` or `.pdf` deliverables where they add real value.
- Private share links.
- Public read-only share links with revoke controls.

## AI Workflow Features

### 6. Summary Templates

Add templates for common outputs:

- Meeting notes.
- Sales call summary.
- Legal/document review.
- Podcast summary.
- Lecture notes.
- Action items only.
- Executive brief.
- Social clips or content ideas.

Allow users to choose a template when summarizing an item.

### 7. Custom Prompts

Let users run reusable prompts against one item or a collection.

Examples:

- “Pull out every action item and owner.”
- “Write a client-ready brief.”
- “Find contradictions or unresolved questions.”
- “Turn this into a blog outline.”

Future version:

- Saved prompt library.
- Per-user custom prompts.
- Prompt templates scoped by media type.

### 8. Collection-Level Intelligence

Make collections more than folders.

For a collection, generate:

- Combined summary.
- Themes across items.
- Timeline.
- Action item rollup.
- Decisions and open questions.
- Client/project brief.

This is one of the strongest product directions because it turns many media items into one useful deliverable.

### 9. Speaker Labels and Diarization

For audio and meetings, add speaker-aware transcripts.

The researched product direction, provider shortlist, quality expectations,
architecture constraints, privacy boundary, and phased delivery plan are in
[`SPEAKER_DIARIZATION_PLAN.md`](SPEAKER_DIARIZATION_PLAN.md).

Capabilities:

- Detect speakers when possible.
- Rename speakers.
- Filter transcript by speaker.
- Extract action items by speaker.
- Include speaker names in summaries and exports.

## Product and Business Features

### 10. Team Workspaces

Eventually support shared use.

Add:

- Invite team members.
- Workspace membership.
- Roles: owner, admin, member.
- Shared collections.
- Activity history.

Do this after single-user workspace flows feel polished.

### 11. Billing and Usage Limits

If this becomes a public product, add Stripe-backed plans.

Track and limit:

- Transcription minutes.
- PDF pages.
- Video transcript jobs.
- AI summary/chat usage.
- Storage.

Also add:

- Usage dashboard.
- Plan limits.
- Upgrade prompts.
- Overages or top-ups.

### 12. Developer Experience

Improve the developer/API area.

Add:

- API key usage stats.
- Last-used details per key.
- Webhook test button.
- Webhook replay.
- Delivery logs with payload/status.
- More interactive API docs.
- Copy-ready examples using the user’s key prefix/context.

## Platform Extensions

### 13. Browser Extension

A browser extension could let users save videos directly from YouTube/Vimeo pages.

Actions:

- Send current video to Media Tools.
- Open existing transcript if already processed.
- Save page/PDF/audio to the workspace.

### 14. Google Drive and Gmail Integrations

Potential imports:

- Drive PDFs.
- Drive recordings.
- Gmail attachments.
- Meeting recordings saved to Drive.

Potential exports:

- Google Docs summaries.
- Drive folders per collection/project.

### 15. Native Mobile Evolution

The separate native SwiftUI app now ships its core capture, unified library,
detail, chat, and collection workflows. Next mobile work should simplify the
five-tab navigation, make settings user-centered, improve compact/iPad layouts,
add offline recording/upload recovery, and only then graduate the prepared
Share Extension and Widget source into signed, tested targets.

## Suggested Implementation Order

1. Better exports and share links.
2. Summary templates and custom prompts.
3. Collection-level intelligence.
4. Speaker diarization.
5. Team workspaces.
6. Billing/usage limits.
7. Browser extension and external integrations.

## Next Recommended Milestone

The next milestone should be shareable outputs and reusable AI workflows.

Suggested scope:

- Private and revocable read-only share links.
- More consistent exports across media types.
- Saved summary templates and reusable prompts.
- Collection-level briefs, action items, and decisions.

This builds on the cohesive workspace foundation without requiring team billing or third-party integration decisions yet.
