# Media Tools — Apple Watch Companion

Record audio from your wrist, get transcriptions on your phone.

## Features

- **One-tap recording** — Big mic button, tap to start/stop
- **Live waveform** — Real-time audio level visualization while recording
- **Content type picker** — Voice memo, meeting, lecture, phone call
- **Status tracking** — See transcription progress in real-time
- **Recent items** — View last 5 transcriptions synced from iPhone
- **Dual mode** — Sends via iPhone (WatchConnectivity) or directly via WiFi/cellular
- **Watch face complication** — Circular, rectangular, inline, and corner styles
- **Haptic feedback** — Tap confirmation on record start/stop

## Architecture

```
MediaToolsWatch/
├── MediaToolsWatchApp.swift              # App entry point
├── Info.plist                            # Mic permission, background audio
├── Views/
│   └── WatchHomeView.swift               # Main UI: record + status + recent
├── Services/
│   ├── WatchConnectivityService.swift    # Phone ↔ Watch communication
│   └── WatchRecorderService.swift        # AVAudioRecorder wrapper
├── Components/
│   └── WatchComplication.swift           # Watch face widget
└── Assets.xcassets/                      # Icon, accent color
```

## How It Works

### Recording Flow
1. User taps mic button on Watch
2. `WatchRecorderService` starts AVAudioRecorder (m4a, 22kHz mono, 64kbps)
3. Timer counts up, waveform shows audio levels
4. User taps stop
5. File sent to iPhone via `WCSession.transferFile()`
6. iPhone's `PhoneConnectivityService` receives file
7. Uploads to Media Tools API for Whisper transcription
8. Status updates flow back to Watch via messages

### Fallback: Direct Upload
If iPhone is not reachable:
1. Watch uploads directly to API via WiFi/cellular
2. Uses shared Keychain for auth token
3. Polls for completion independently
4. Shows "Direct mode" badge

### Data Flow
```
Watch → (WatchConnectivity transferFile) → iPhone → (HTTP upload) → API
Watch ← (WatchConnectivity message) ← iPhone ← (HTTP poll) ← API

OR (fallback):
Watch → (HTTP upload) → API
Watch ← (HTTP poll) ← API
```

## Setup in Xcode

1. File → New → Target → watchOS → App
2. Name: `MediaToolsWatch`
3. Embed in: `MediaTools` (iPhone app)
4. Replace generated files with these source files
5. Add to both iPhone and Watch targets:
   - `Shared/WatchConnectivityConstants.swift`
6. Watch target capabilities:
   - **App Groups**: `group.com.shimizu-technology.media-tools`
   - **Keychain Sharing**: `group.com.shimizu-technology.media-tools`
7. For complication: File → New → Target → Widget Extension (watchOS)
   - Replace with `WatchComplication.swift`

## Audio Format

| Setting | Value | Why |
|---------|-------|-----|
| Format | AAC (m4a) | Best compression for speech |
| Sample Rate | 22,050 Hz | Sufficient for voice, half the iPhone rate |
| Channels | 1 (Mono) | Watch has one mic |
| Bit Rate | 64 kbps | ~480KB/min, good quality-to-size |
| Quality | Medium | Saves Watch battery |

Estimated file sizes:
- 1 minute: ~480 KB
- 5 minutes: ~2.4 MB
- 30 minutes: ~14 MB
- 1 hour: ~29 MB

## Testing

1. Pair your Apple Watch with your iPhone
2. In Xcode, select the MediaToolsWatch target
3. Choose your Apple Watch as the run destination
4. Hit Run (⌘R)
5. The Watch app appears on your Watch
6. Test recording → check iPhone app for the transcription
