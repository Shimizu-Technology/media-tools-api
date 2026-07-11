# Media Tools iOS App

Native SwiftUI app for Media Tools API — transcribe videos, record audio, manage collections, and chat with AI about your content.

## Requirements

- Xcode 16+
- iOS 18+
- Swift 6
- Active Media Tools API instance

## Setup

### 1. Open the Xcode Project

Open `ios/MediaTools/MediaTools.xcodeproj`. The main app and unit/UI test
targets are already configured.

### 2. Add Swift Package Dependencies

File → Add Package Dependencies:
- **Clerk iOS SDK**: `https://github.com/clerk/clerk-ios`
  - Add both `ClerkKit` and `ClerkKitUI` to the MediaTools target

### 3. Optional Extension Targets

The Share Extension and Widget source files are included in this repository,
but they are not yet wired into the checked-in Xcode project. Do not treat
either extension as shipping until these targets, capabilities, signing, and
on-device behavior have been verified.

**Share Extension:**
1. File → New → Target → Share Extension
2. Name: `ShareExtension`
3. Replace generated files with our `ShareExtension/ShareViewController.swift` and `Info.plist`

**Widget:**
1. File → New → Target → Widget Extension
2. Name: `MediaToolsWidget`
3. Replace generated files with our `MediaToolsWidget/MediaToolsWidget.swift`

### 4. Configure Capabilities

**Main App Target (MediaTools):**
- Signing & Capabilities → Add:
  - **Associated Domains**: `webcredentials:welcomed-earwig-86.clerk.accounts.dev`
  - **Keychain Sharing**: `group.com.shimizu-technology.media-tools`
  - **App Groups**: `group.com.shimizu-technology.media-tools`

**Share Extension & Widget:**
- Add **Keychain Sharing**: `group.com.shimizu-technology.media-tools`
- Add **App Groups**: `group.com.shimizu-technology.media-tools`

### 5. Configure Clerk

1. Go to [Clerk Dashboard](https://dashboard.clerk.com) → Native Applications
2. Enable **Native API**
3. Add your iOS app (App ID Prefix + Bundle ID)

### 6. Generate App Icon

```bash
swift ios/scripts/generate-icon.swift
```

### 7. Build & Run

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
│   └── Models.swift                 # Codable API models (Transcript, Audio, PDF, etc.)
│
├── Services/
│   ├── APIClient.swift              # HTTP client with Clerk JWT auth + multipart
│   ├── MediaToolsService.swift      # Domain service (CRUD for all item types)
│   ├── KeychainService.swift        # Shared keychain for app ↔ extension auth
│   ├── TokenSyncService.swift       # Syncs Clerk token to keychain every 50s
│   ├── NotificationService.swift    # Local notifications on completion
│   ├── BackgroundUploadService.swift # Background URLSession for large files
│   ├── WidgetService.swift          # Updates widget via shared UserDefaults
│   └── SpotlightService.swift       # CoreSpotlight indexing for system search
│
├── Views/
│   ├── MainTabView.swift            # 5-tab layout
│   ├── OnboardingView.swift         # First-launch walkthrough (4 pages)
│   ├── Library/
│   │   ├── LibraryView.swift        # Segmented list with search + swipe actions
│   │   ├── ItemDetailView.swift     # Detail + chat/summary/copy/share/collect
│   │   ├── TranscribeView.swift     # URL input with paste + polling
│   │   └── PDFUploadView.swift      # File picker with security-scoped access
│   ├── Audio/
│   │   └── RecordView.swift         # AVAudioRecorder + content type picker
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
└── MediaToolsWidget/                # Home Screen Widget
    └── MediaToolsWidget.swift       # Small + Medium sizes, recent items
```

## Features

### Core
- **Library** — Browse all transcripts, audio, and PDFs with search and segmented tabs
- **Transcribe** — Paste any video URL for transcription with real-time polling
- **Record** — AVAudioRecorder with content type presets (meeting, lecture, phone call, etc.)
- **Collections** — Group items together, chat with AI about entire collections
- **AI Chat** — Ask questions about any transcript, get summaries and key points
- **PDF Upload** — Import PDFs from Files app for text extraction

### iOS Integration
- **Share Sheet source** — Prepared for a future Share Extension target; not currently shipped
- **Home Screen Widget source** — Prepared for a future Widget target; not currently shipped
- **Spotlight Search** — Find transcripts from iOS system search
- **Local Notifications** — Get notified when transcriptions complete
- **Background upload service** — Implemented as a service, but not yet connected to the active upload flow
- **Haptic Feedback** — Tactile responses on key actions
- **Swipe Actions** — Swipe to delete or add to collection

### Auth
- **Clerk iOS SDK v1** — Native sign-in/sign-up with prebuilt `AuthView`
- **Keychain Sharing** — Auth token shared between app and share extension
- **Token Sync** — Automatically refreshes shared token every 50 seconds

### UX
- **Onboarding** — 4-page walkthrough on first launch
- **Pull to Refresh** — Refresh library data with gesture
- **Content Unavailable Views** — Helpful empty states throughout
- **Text Selection** — Long-press to select/copy transcript text
