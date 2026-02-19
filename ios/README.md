# Media Tools iOS App

Native SwiftUI app for Media Tools API — transcribe videos, record audio, manage collections, and chat with AI about your content.

## Requirements

- Xcode 16+
- iOS 18+
- Swift 6
- Active Media Tools API instance

## Setup

### 1. Open in Xcode

Open `ios/MediaTools/` in Xcode. The project uses Swift Package Manager for dependencies.

### 2. Add Dependencies (Swift Package Manager)

Add the following packages:
- **Clerk iOS SDK**: `https://github.com/clerk/clerk-ios`
  - Add both `ClerkKit` and `ClerkKitUI` to the MediaTools target

### 3. Create Xcode Project

Since the Xcode project file (`.xcodeproj`) can't be generated from CLI, create it manually:

1. Open Xcode → File → New → Project
2. Select **App** (iOS)
3. Product Name: `MediaTools`
4. Organization: `com.shimizu-technology`
5. Interface: **SwiftUI**
6. Language: **Swift**
7. Save in `ios/MediaTools/`
8. Delete the generated `ContentView.swift` and `MediaToolsApp.swift` (we have our own)
9. Add all `.swift` files from this directory structure

### 4. Configure Targets

**Main App Target (MediaTools):**
- Add `ClerkKit` and `ClerkKitUI` frameworks
- Add Associated Domain: `webcredentials:welcomed-earwig-86.clerk.accounts.dev`
- Add Keychain Sharing: `group.com.shimizu-technology.media-tools`
- Add App Group: `group.com.shimizu-technology.media-tools`

**Share Extension Target (ShareExtension):**
- File → New → Target → Share Extension
- Name: `ShareExtension`
- Replace generated files with our `ShareViewController.swift` and `Info.plist`
- Add Keychain Sharing: `group.com.shimizu-technology.media-tools` (same group)

### 5. Configure Clerk

1. Go to [Clerk Dashboard](https://dashboard.clerk.com) → Native Applications
2. Enable **Native API**
3. Add your iOS app (App ID Prefix + Bundle ID)

### 6. Build & Run

Select your device or simulator and hit Run (⌘R).

## Architecture

```
MediaTools/
├── MediaToolsApp.swift          # App entry point, Clerk config
├── Configuration.swift          # API URL, Clerk key, keychain groups
├── ContentView.swift            # Auth gate (welcome vs main)
├── Models/
│   └── Models.swift             # API data models (Codable)
├── Services/
│   ├── APIClient.swift          # HTTP client with Clerk auth
│   └── MediaToolsService.swift  # Domain service layer
├── Views/
│   ├── MainTabView.swift        # Tab bar (Library, Transcribe, Record, Collections, Settings)
│   ├── Library/
│   │   ├── LibraryView.swift    # Library list with search
│   │   ├── ItemDetailView.swift # Transcript/audio/PDF detail + actions
│   │   └── TranscribeView.swift # URL submission with polling
│   ├── Audio/
│   │   └── RecordView.swift     # Audio recording + upload
│   ├── Chat/
│   │   └── ChatView.swift       # AI chat (reused for all item types)
│   ├── Collections/
│   │   └── CollectionsListView.swift  # Collection CRUD + detail
│   └── Settings/
│       └── SettingsView.swift   # Account, API health, about
└── ShareExtension/
    ├── ShareViewController.swift # iOS Share Sheet handler
    └── Info.plist               # Extension config (URLs + files)
```

## Features

- **Library**: Browse all transcripts, audio, and PDFs with search
- **Transcribe**: Paste any video URL (YouTube, Vimeo, etc.) for transcription
- **Record**: Record audio with AVAudioRecorder, upload for transcription
- **Collections**: Group items, chat with AI about entire collections
- **Chat**: AI-powered Q&A about any transcript or collection
- **Share Sheet**: Share URLs/files from any iOS app directly into Media Tools
- **Clerk Auth**: Native sign-in/sign-up with prebuilt UI components
