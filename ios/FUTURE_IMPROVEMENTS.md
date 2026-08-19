# Media Tools iOS — Future Improvements & Roadmap

> Living document for planned features, ideas, and enhancements.
> Organized by effort and impact. Update as features are completed.

---

## 🔥 Tier 1: High Impact / Low Effort

### 1. Siri Shortcuts & App Intents
- "Hey Siri, transcribe this video" → opens app with URL paste
- "Summarize my last recording" → returns AI summary via Siri
- "What did I record today?" → lists today's transcriptions
- Uses Apple's App Intents framework (SwiftUI native)
- **Why:** Makes the app feel native, hands-free usage while driving/walking

### 2. Live Activity & Dynamic Island
- Show transcription/upload progress on Lock Screen and Dynamic Island
- Real-time word count as transcription streams in
- "Transcription complete" dismisses automatically
- Uses ActivityKit framework
- **Why:** Users don't need to keep the app open to know when it's done

### 3. Quick Actions (Home Screen)
- Long-press app icon → "New Transcription", "Record Audio", "My Library"
- Uses UIApplicationShortcutItem
- **Why:** Faster access to core actions, 2 seconds to start recording

### 4. Drag & Drop (iPad)
- Drag audio/PDF files from Files app directly into Media Tools
- Drag transcripts out to other apps as text
- **Why:** iPad power users expect this, makes the app feel first-class

### 5. Markdown Rendering
- Render summaries with proper headers, bold, lists, code blocks
- Swift's `AttributedString` supports markdown natively
- Apply in chat messages, summaries, and transcript display
- **Why:** Summaries look way better formatted than raw text

---

## 💡 Tier 2: Medium Effort / Big Value

### 6. Offline Queue
- Record audio offline → stored locally → auto-uploads when back online
- Paste URLs offline → queued → submitted when connected
- Uses Core Data or SwiftData for local queue
- Background URLSession handles deferred uploads
- Progress syncs when back online
- **Why:** Critical for on-the-go usage, unreliable connections

### 7. Apple Watch Companion App ⭐ (Leon's Pick)
- **Record:** Tap to record voice memo from wrist
- **Status:** See "Transcribing..." progress on watch face
- **Complication:** Show latest transcription status
- **Quick summary:** "Hey Siri, summarize my last recording" from watch
- Uses WatchConnectivity framework to sync with iPhone app
- Audio recorded on Watch → transferred to iPhone → uploaded to API
- **Why:** Record meetings, lectures, ideas without pulling out your phone

### 8. iPad Split View / Multi-Column Layout
- Side-by-side: transcript text + AI chat panel
- NavigationSplitView with three columns on iPad
- Optimized for iPad Pro landscape
- **Why:** Actually useful for working with content, not just viewing

### 9. Speaker Diarization
- "Speaker 1 said X, Speaker 2 said Y"
- Requires Whisper + pyannote or similar on backend
- Show speaker labels in transcript, filter by speaker
- **Why:** Meeting recordings become actually actionable

### 10. Multi-Language Translation
- Transcribe in any language Whisper supports
- Auto-detect source language
- One-tap translation to English (or any target)
- Bilingual display: original + translated side by side
- **Why:** Code School has international content; Guam is multilingual

---

## 🚀 Tier 3: Ambitious / Killer Features

### 11. On-Device Whisper
- Run Whisper locally on iPhone (Apple Neural Engine)
- Instant transcription without network
- Privacy: audio never leaves the device
- Fallback to cloud for higher accuracy
- Could use whisper.cpp or Apple's Speech framework
- **Why:** Speed, privacy, works anywhere

### 12. Live Transcription Mode
- Real-time transcription while recording
- Words appear as you speak (streaming audio)
- Live captions overlay during meetings
- Save transcript when recording stops
- **Why:** See what's being said in real-time, accessibility

### 13. Calendar Integration & Auto-Record
- Connect to Apple Calendar
- "Meeting with Steve at 2pm" → notification: "Start recording?"
- Auto-creates a transcription tagged with meeting name/attendees
- Post-meeting: auto-summarize with action items
- **Why:** Seamless meeting workflow, zero manual steps

### 14. Podcast Feed Integration
- Subscribe to podcast RSS feeds
- Auto-transcribe new episodes in background
- Search across all podcast transcripts
- "What did Tim Ferriss say about morning routines?"
- **Why:** Makes podcast content searchable and actionable

### 15. Daily Digest
- Push notification at end of day: "You recorded 3 items today"
- AI-generated summary of everything you captured
- Weekly/monthly trends: "You've been recording more meetings about Project X"
- **Why:** Passive intelligence about your own content patterns

---

## 🌐 Tier 4: Platform Expansion

### 16. Image & Screenshot OCR
- Camera: snap whiteboard, document, menu, receipt
- Screenshot: extract text from any screenshot
- AI chat about extracted text ("What does this contract clause mean?")
- Add to collections alongside transcripts
- Uses Apple Vision framework + backend OCR
- **Why:** "Media Tools" should handle ALL media, not just audio/video

### 17. Web Clipper / Bookmark Saver
- Share a web article → extracts readable content
- AI summary of the article
- Save to library, add to collections
- Search across all saved articles
- **Why:** Unified knowledge base for everything you consume

### 18. Voice-to-Formatted-Notes
- Speak naturally: "Email Steve about the tournament, mention the $50K prize pool"
- AI turns it into a formatted email draft, todo item, or structured note
- Different output formats: email, bullet points, action items, meeting notes
- **Why:** Fastest way to capture structured thoughts

### 19. Video Summarizer with Timestamps
- Auto-generate chapter markers for long videos
- "Skip to the part about marketing strategy" → jumps to timestamp
- Visual timeline with topic segments
- Export chapters as YouTube-compatible timestamps
- **Why:** Makes long content navigable and shareable

### 20. Smart Tags & Auto-Categorization
- AI auto-tags every item: topic, people mentioned, project, urgency
- Filter library by tags
- "Show me everything about the Marianas Open"
- Tag suggestions improve over time
- **Why:** Organization without manual effort

### 21. Team Shared Workspace
- Cornerstone team: shared collections, shared chat context
- Role-based access (admin, member, viewer)
- Team activity feed: "Leon added 3 recordings today"
- Shared AI context: "What has our team discussed about X?"
- **Why:** Multiplayer knowledge base for small teams

### 22. Screen Recording Transcription
- Record screen + narration from iOS
- Extract audio → transcribe
- Screenshots synced with transcript timestamps
- Great for tutorials, bug reports, walkthroughs
- **Why:** Training content creation for Code School

### 23. Audio Enhancement / Noise Reduction
- Clean up noisy recordings before transcription
- Remove background noise, echo cancellation
- Normalize volume levels
- Preview before/after
- **Why:** Better input = better transcription accuracy

---

## ✅ Completed

- [x] Core iOS app (SwiftUI, 5 tabs, full feature parity with web)
- [ ] Wire and validate the prepared Share Sheet extension target (URLs, audio, PDFs)
- [ ] Wire and validate the prepared Home Screen widget target (small + medium)
- [x] Spotlight search indexing
- [x] Local notifications on completion
- [x] Durable app-level recording, background audio, interruption handling, and local recovery queue
- [ ] Connect and validate the prepared background upload service in the active upload flow
- [x] Onboarding walkthrough
- [x] Audio playback with speed control
- [x] Export (txt/md/json)
- [x] Sort/filter/bulk actions in library
- [x] Summary content type picker (7 types)
- [x] Design system matching web frontend
- [x] App icon (generated waveform)
- [x] Keychain token sync for share extension

---

## Priority Order (Leon's Input)

1. **Quick Capture controls** — App Shortcut, Action Button/Back Tap mapping, Lock Screen widget
2. Live Activity and system recording controls
3. Background upload and offline retry queue
4. **Apple Watch companion**
5. Image OCR
6. iPad layout
7. Everything else by impact/effort

---

*Last updated: 2026-08-19*
