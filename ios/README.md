# Media Tools iOS App

Native SwiftUI app for Media Tools API — transcribe videos, record audio, manage collections, and chat with AI about your content.

## Requirements

- Xcode 16.4+
- iOS 18.5+
- Swift 5 language mode (compiled by the Xcode 16.4 toolchain)
- Active Media Tools API instance

## Setup

### 1. Open the Xcode Project

Open `ios/MediaTools/MediaTools.xcodeproj`. The main app and unit/UI test
targets are already configured.

The checked-in project already includes `ClerkKit` and `ClerkKitUI` as Swift
Package Manager dependencies. Xcode resolves them automatically; do not add a
second package reference.

### 2. Understand the Extension Targets

The checked-in `MediaToolsWidget` target ships the Quick Record Home/Lock
Screen widget, Control Center control, and recording Live Activity. It shares
only App Intent and ActivityKit value types with the host app; the recording
coordinator and protected audio store remain owned by the app process.

The Share Extension source remains a prototype and is not wired into the
checked-in project. Do not treat it as shipping until its target, bundle ID,
entitlements, signing, App Group/Keychain groups, and on-device behavior have
been verified.

### 3. Configure Clerk

1. Go to [Clerk Dashboard](https://dashboard.clerk.com) → Native Applications
2. Enable **Native API**
3. Add bundle ID `com.ShimizuTechnology.MediaTools`

Debug builds include the public Clerk publishable key as a development
fallback. Release builds must supply `CLERK_PUBLISHABLE_KEY` through an Xcode
build setting or generated Info.plist value. A Clerk publishable key is client
configuration; never place `CLERK_SECRET_KEY`, AI keys, database credentials,
or the Media Tools admin key in the iOS target.

`API_BASE_URL` can also be supplied as a build setting. It otherwise defaults
to the production Render API. Use a local HTTP URL only for simulator
development; `Info.plist` permits local networking but does not relax transport
security for arbitrary remote hosts.

### 4. Generate App Icon (only when replacing it)

```bash
swift ios/scripts/generate-icon.swift
```

### 5. Build & Run

Select your device or simulator and hit Run (⌘R).

## Architecture

```
MediaTools/
├── MediaToolsApp.swift              # Entry point, Clerk config, onboarding gate
├── Configuration.swift              # API URL, Clerk key, keychain/app groups
├── ContentView.swift                # Auth gate (welcome vs main tab view)
├── Info.plist                       # Permissions (mic), ATS config
│
├── Models/
│   ├── Models.swift                 # Codable API models (Transcript, Audio, PDF, etc.)
│   └── LocalRecording.swift         # Durable device-local capture metadata
│
├── Services/
│   ├── APIClient.swift              # HTTP client with Clerk JWT auth + multipart
│   ├── MediaToolsService.swift      # Domain service (CRUD for all item types)
│   ├── KeychainService.swift        # Shared keychain for app ↔ extension auth
│   ├── TokenSyncService.swift       # Syncs Clerk token to keychain every 50s
│   ├── NotificationService.swift    # Local notifications on completion
│   ├── BackgroundUploadService.swift # Background URLSession for large files
│   ├── RecordingCoordinator.swift   # App-level capture + interruption handling
│   ├── RecordingActivityManager.swift # Recording Live Activity lifecycle
│   ├── RecordingStore.swift         # Protected audio files + atomic queue manifest
│   ├── WidgetService.swift          # Updates widget via shared UserDefaults
│   └── SpotlightService.swift       # CoreSpotlight indexing for system search
│
├── Views/
│   ├── MainTabView.swift            # Current five-tab navigation
│   ├── OnboardingView.swift         # First-launch walkthrough (4 pages)
│   ├── Library/
│   │   ├── LibraryView.swift        # Unified paginated library + typed actions
│   │   ├── ItemDetailView.swift     # Detail + chat/summary/copy/share/collect
│   │   ├── TranscribeView.swift     # URL capture and visible status updates
│   │   └── PDFUploadView.swift      # File picker with security-scoped access
│   ├── Audio/
│   │   └── RecordView.swift         # Capture controls + recoverable local queue
│   ├── Chat/
│   │   └── ChatView.swift           # Reusable AI chat (all item types)
│   ├── Collections/
│   │   └── CollectionsListView.swift # CRUD + detail + collection chat
│   └── Settings/
│       └── SettingsView.swift       # Clerk profile, API health, about
│
├── Components/
│   └── AddToCollectionSheet.swift   # Modal for adding items to collections
│
├── Extensions/
│   ├── Haptics.swift                # Tactile feedback helpers
│   ├── SwipeActions.swift           # Library row swipe (delete + collect)
│   └── URL+MediaTools.swift         # Video/audio/PDF URL detection
│
├── Assets.xcassets/
│   ├── AccentColor (teal #2F9E8F)
│   └── AppIcon (1024x1024 waveform)
│
├── ShareExtension/                  # iOS Share Sheet
│   ├── ShareViewController.swift    # Handles URLs + audio + PDF files
│   └── Info.plist                   # Activation rules
│
├── MediaToolsShared/                # Types compiled into app + widget extension
│   ├── QuickCaptureIntents.swift    # Action Button/Siri/Shortcuts recording actions
│   └── RecordingActivityAttributes.swift
│
└── MediaToolsWidget/                # Shipping WidgetKit extension
    ├── MediaToolsWidget.swift       # Widget, system control, Live Activity
    └── Info.plist
```

## Features

### Core
- **Library** — Server-side search, pagination, filters, sorting, selection, and
  typed actions across videos, recordings, and PDFs
- **Transcribe** — Paste a supported video URL and follow its processing state
- **Record** — Record or import audio/video with semantic presets, continue a
  user-initiated recording through screen lock/backgrounding, recover local
  captures after relaunch or interruption, and retain audio until the API has
  accepted its transcription job
- **Collections** — Group items together, chat with AI about entire collections
- **AI Chat** — Ask questions about any transcript, get summaries and key points
- **PDF Upload** — Import PDFs from Files app for text extraction

### iOS Integration
- **Share Sheet source** — Prepared for a future Share Extension target; not currently shipped
- **Quick Capture** — Start/stop recording from Shortcuts, Siri, the Action
  Button, Back Tap, Control Center, or the Quick Record widget
- **Live Activity** — Persistent recording state, timer, and Stop & Save action
  on the Lock Screen and Dynamic Island
- **Spotlight Search** — Find completed videos, recordings, and PDFs; deletion
  removes the corresponding typed search entry
- **Local Notifications** — Get notified when transcriptions complete
- **Background recording** — User-initiated microphone capture is owned at the
  app level, supports Bluetooth input, and survives tab changes and ordinary
  backgrounding; the audio session ends immediately when capture stops
- **Background upload service source** — Present but not wired to the active
  flow; current recording uploads must be treated as foreground app work
- **Haptic Feedback** — Tactile responses on key actions
- **Swipe Actions** — Swipe to delete or add to collection

## Configure Quick Record on an iPhone

1. Open Media Tools once and allow microphone access.
2. Open **Shortcuts** and confirm **Media Tools → Quick Record** is available.
3. For an iPhone Action Button, open **Settings → Action Button**, choose
   **Shortcut**, then select **Quick Record**.
4. Press once to start. Press again, say “Stop recording with Media Tools,” or
   use **Stop & Save** on the Live Activity to finish.

The same Quick Record action can be assigned in **Settings → Accessibility →
Touch → Back Tap** or added as a Control Center control. A system-triggered
recording requires both microphone permission and Live Activities; Media Tools
shows a clear setup message if either is disabled. An ordinary recording
started inside the visible app can continue without Live Activities.

### Auth
- **Clerk iOS SDK v1** — Native sign-in/sign-up with prebuilt `AuthView`
- **Keychain preparation** — Device-only shared-token storage code exists for a
  future extension, but extension entitlements/targets do not currently ship
- **Token Sync** — Refreshes that prepared shared token while signed in

### UX
- **Onboarding** — 4-page walkthrough on first launch
- **Pull to Refresh** — Refresh library data with gesture
- **Content Unavailable Views** — Helpful empty states throughout
- **Text Selection** — Long-press to select/copy transcript text

## Verification

From the repository root, `make gate` runs native unit tests and verifies that
the built app installs and launches when Xcode is available. Native UI changes
should additionally run the relevant `MediaToolsUITests` on an iPhone 16 Pro
and a compact iPhone simulator, followed by a visual interaction pass.
