# Media Tools iOS App

Native SwiftUI app for Media Tools API — transcribe videos, record audio, manage collections, and chat with AI about your content.

## Requirements

- Xcode 26+ for TestFlight or App Store archives
- iOS 18.5+
- Swift 5 language mode
- Active Media Tools API instance

## Setup

### 1. Open the Xcode Project

Open `ios/MediaTools/MediaTools.xcodeproj`. The main app and unit/UI test
targets are already configured.

The project has no third-party package dependencies.

### 2. Understand the Extension Targets

The checked-in `MediaToolsWidget` target ships the Quick Record Home/Lock
Screen widget, Control Center control, and recording Live Activity. It shares
only App Intent and ActivityKit value types with the host app; the recording
coordinator and protected audio store remain owned by the app process.

The Share Extension target is embedded in the app. It copies supported audio
and MP4 files into an App Group inbox, and when the app has published permission
and a capture key, starts the upload itself. See [Auth](#auth). Verify App Group
provisioning for both bundle IDs before TestFlight. Use that build to test Voice
Memos and Files sharing on a physical iPhone before public release.

### 3. Point at an API

`API_BASE_URL` can also be supplied as a build setting. It otherwise defaults
to the production Render API. Use a local HTTP URL only for simulator
development; `Info.plist` permits local networking but does not relax transport
security for arbitrary remote hosts.

### Passkey domain association

The app is prepared to use passkeys for
`media.shimizu-technology.com`. Its Associated Domains entitlement is
`webcredentials:media.shimizu-technology.com`, and the site serves
`/.well-known/apple-app-site-association` with the verified app identifier
`4T358A5S74.com.ShimizuTechnology.MediaTools`. Keep the web passkey relying
party ID on this domain: changing it would require registering new passkeys.
The app uses this association for passkey enrollment and sign-in.

Before distributing a passkey-enabled iOS build, verify that the production
association URL responds with JSON and no redirect, that the Apple Developer
App ID has Associated Domains enabled, and that the signed app and provisioning
profile contain the entitlement. The Share Extension does not request passkeys.

### 4. Generate App Icon (only when replacing it)

```bash
swift ios/scripts/generate-icon.swift
```

### 5. Build & Run

Select your device or simulator and hit Run (⌘R).

### 6. Run release preflight

Apple requires iOS submissions to use the iOS 26 SDK or later. Validate the
source configuration before archiving, then validate the signed archive itself:

```bash
make ios-release-preflight
make ios-release-preflight ARCHIVE_PATH=/path/to/MediaTools.xcarchive
make ios-release-preflight \
  ARCHIVE_PATH=/path/to/MediaTools.xcarchive \
  EXPORT_PATH=/path/to/AppStoreExport
```

The checked-in App Store copy, privacy-label mapping, review notes, export
options, and remaining launch checks live in `ios/app-store/`. Preflight fails if
a third-party sign-in SDK, its package reference, its build settings, or its
entitlement return. Before App Review, create and verify a dedicated account
and provide its non-expiring review credentials outside this repository.

## Architecture

```
MediaTools/
├── MediaToolsApp.swift              # Entry point, onboarding gate
├── Configuration.swift              # API URL, app group
├── ContentView.swift                # Auth gate (welcome vs main tab view)
├── Info.plist                       # Permissions (mic), ATS config
│
├── Models/
│   ├── Models.swift                 # Codable API models (Transcript, Audio, PDF, etc.)
│   └── LocalRecording.swift         # Durable device-local capture metadata
│
├── Services/
│   ├── APIClient.swift              # HTTP client with device-session auth + multipart
│   ├── MediaToolsService.swift      # Domain service (CRUD for all item types)
│   ├── DeviceSessionController.swift # Stored device session, refresh, revocation
│   ├── FirstPartyAuthService.swift  # Sign-up, sign-in, reset, email, passkeys
│   ├── ShareUploadKeyManager.swift  # Capture key the Share Extension uploads with
│   ├── NotificationService.swift    # Local notifications on completion
│   ├── BackgroundUploadService.swift # Background URLSession for large files
│   ├── RecordingCoordinator.swift   # App-level capture + interruption handling
│   ├── RecordingActivityManager.swift # Recording Live Activity lifecycle
│   ├── RecordingStore.swift         # Protected audio files + atomic queue manifest
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
│       └── SettingsView.swift       # Account, usage, devices, security, deletion
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
- **Share Sheet source** — Save a Voice Memo or supported media file from another app into a durable, local recording queue
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

iOS does not allow a general-purpose app to activate the microphone from a
completely cold background process. Quick Record therefore brings Media Tools
to the foreground and starts capture automatically in one press. Once capture
has started, it continues through screen lock and normal app switching, and the
Live Activity provides a visible Stop action.

### Auth
- **Accounts** — Email and password, owned by Media Tools. Sign-up emails a code,
  and the password is chosen with that code. The API has the contract in
  `docs/AUTH_API.md`. Passkeys and recovery codes are secondary. Create account
  shows only while the API reports `signup_enabled`.
- **Device session** — The app stores a rotating refresh credential in the
  device-only Keychain and uses short access credentials for API calls. Signing
  out revokes and clears it. If the API cannot confirm revocation, the app stops
  using it, signs out locally, and keeps the Keychain item only to retry later.
- **Sessions from older builds** — A session build 13 stored through the retired
  provider carries that provider's source value and user ID. It keeps decoding and is
  converted on load. The provider ID moves to a local owner mapping, which holds
  no credentials, because recordings and AI consent from that era are keyed by it.
  `migrateOwnerID` moves them to the server's user ID. The mapping is removed on
  account deletion. Build 13 also saved a journal before asking for a first session.
  If the response was lost, its token is the session's only copy, so with no stored
  session the app refreshes with it before showing sign-in. Only a rejection from
  the server ends it; offline, the app shows that it is reconnecting and retries.
  A sign-out build 13 had not finished is recovered only to revoke it.
- **Share uploads** — The extension never receives the device session. At sign-in,
  and on the first launch of a session that predates this, the app mints an API key
  with only `capture:upload` and stores it in the App Group's Keychain access group,
  bound to its account. It also writes the account's AI consent and "Automatically
  transcribe" answers to a file in the App Group. With both present, a shared audio
  file is presigned with that key and handed to a background `URLSession`, reading
  from the file so a large share stays inside the extension's memory limit. iOS
  wakes the app with `handleEventsForBackgroundURLSession` to finish it. The share's
  ID becomes the recording's ID, so importing it never uploads twice. Permission
  and the key are read again after presigning, just before the transfer starts.
  Without a key or permission, or after any failure, the share waits in the inbox
  as before.
  Any end of the session removes the key from the iPhone at once, and it is revoked
  on the server when a session of that account can do so. A password reset revokes
  it on the server too; the extension's next 401 removes the local copy, and the app
  mints another once signed in. A key whose mint response was lost is found by this
  install's key name. Until that check succeeds, it repeats on every launch and at
  sign-out, even while the saved key is reused.
- **Who finishes a share** — The server counts two objects as two uploads, so one
  share may complete only one. When a transfer goes quiet, the extension (its bytes
  arrived) and the app (it will send its own copy) race to create one claim file in
  the share's App Group folder. The file is a hard link, so it appears complete or
  not at all. The loser stands down: the app completes the extension's object, or
  the extension abandons it. The claim lasts as long as the folder, and a share with
  no folder has no competing upload.
- **Keychain groups** — Do not add a `keychain-access-groups` entitlement. Its first
  entry would become the default for new items, and the device session, saved with
  no explicit group, would land where the extension can read it. iOS already treats
  the App Group as an access group. Preflight enforces this.

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
