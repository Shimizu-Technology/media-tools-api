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

Possible route shape:

- `/app/items/:type/:id`
- or `/app/library/:type/:id`

Each detail page should include:

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

Search should cover:

- Video transcripts.
- Audio transcriptions.
- PDF text.
- Summaries.
- Collections.
- Eventually chat history.

Start with Postgres full-text search and filters. Consider semantic/vector search later.

Useful filters:

- Type: video, audio, PDF.
- Status: processing, completed, failed.
- Date range.
- Collection.
- Tags/favorites once those exist.

### 3. Better Library Organization

The library now supports starred items, tags, archive, status filters, sorting, collections, and bulk deletion.

Add:

- Tags.
- Favorites/starred items.
- Archive.
- Client/project labels.
- Saved filters.
- Bulk actions.
- Better type/status/date sorting.

Collections remain useful for grouped work, but tags and favorites make everyday organization faster.

### 4. Processing Center

The processing center now shows queued, active, failed, and recently completed work with automatic refresh and links to recovery actions.

Show:

- Active jobs.
- Queued jobs.
- Failed jobs.
- Retry buttons.
- Error messages.
- Recently completed items.
- Upload/transcription progress when available.

Why this matters: video/audio/PDF processing can take time, so users need confidence that work is still moving.

### 5. Share and Export Improvements

Make it easy to move results out of the app.

Add per-item actions for:

- Copy transcript/text.
- Copy summary.
- Export as `.txt`, `.md`, `.json`, and eventually `.docx` or `.pdf`.
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

### 15. PWA and Mobile Capture

Improve mobile usage before building a separate native app.

Add:

- Installable PWA behavior.
- Better mobile recording flow.
- Offline recording draft protection.
- Share-sheet-friendly upload path later.

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
