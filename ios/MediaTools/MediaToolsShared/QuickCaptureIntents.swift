import AppIntents

/// The single action Leon can map to the iPhone Action Button or Back Tap.
/// A second invocation stops the current recording, matching a physical toggle.
/// LiveActivityIntent guarantees that iOS runs the implementation in the host
/// app process instead of the short-lived WidgetKit extension process.
struct QuickRecordIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Quick Record"
    static let description = IntentDescription(
        "Open Media Tools and start a private voice recording, or stop and save the recording already in progress."
    )

    // iOS deliberately blocks a general-purpose microphone session from being
    // activated by a cold, background-only process. Foregrounding first keeps
    // the Action Button a one-press workflow while satisfying that privacy
    // boundary; capture continues normally after the phone locks or the person
    // switches apps.
    static let openAppWhenRun = true

    // IntentModes was introduced with the iOS 26 SDK. Keep Xcode 16 / iOS 18
    // builders on openAppWhenRun while newer SDKs express the same foreground
    // requirement through the replacement API.
    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.foreground(.immediate)] }
    #endif

    @MainActor
    func perform() async throws -> some IntentResult {
        #if WIDGET_EXTENSION
        // The system executes LiveActivityIntent in the app process. This body
        // only lets the widget extension compile and expose intent metadata.
        return .result()
        #else
        _ = await RecordingCoordinator.shared.toggleFromSystem()
        NotificationCenter.default.post(name: .mediaToolsQuickCapture, object: nil)
        return .result()
        #endif
    }
}

/// Used by the Live Activity's explicit Stop button. Keeping this separate from
/// the toggle prevents a delayed double tap from accidentally starting another
/// recording after the first one has stopped.
struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription("Stop and safely save the active Media Tools recording.")

    @MainActor
    func perform() async throws -> some IntentResult {
        #if WIDGET_EXTENSION
        return .result()
        #else
        _ = await RecordingCoordinator.shared.stopFromSystem()
        return .result()
        #endif
    }
}

extension Notification.Name {
    static let mediaToolsQuickCapture = Notification.Name("MediaToolsQuickCapture")
}

struct MediaToolsAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: QuickRecordIntent(),
            phrases: [
                "Quick record with \(.applicationName)",
                "Start recording with \(.applicationName)",
                "Toggle \(.applicationName) recording",
            ],
            shortTitle: "Quick Record",
            systemImageName: "mic.fill"
        )

        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: [
                "Stop recording with \(.applicationName)",
                "Save my \(.applicationName) recording",
            ],
            shortTitle: "Stop Recording",
            systemImageName: "stop.circle.fill"
        )
    }
}
