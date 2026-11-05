import SwiftUI

@main
struct MediaToolsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var recordingCoordinator = RecordingCoordinator.shared
    @State private var uploadCoordinator = RecordingUploadCoordinator.shared
    @State private var aiProcessingConsent = AIProcessingConsentManager.shared
    @State private var deviceSession = DeviceSessionController.shared

    init() {
        ShareUploadKeyManager.shared.follow(DeviceSessionController.shared)
        MediaToolsAppShortcuts.updateAppShortcutParameters()
        #if DEBUG
        // Exercise the real cold-launch handoff in UI tests: publish the route
        // before MainView exists, just as an Action Button intent can.
        if ProcessInfo.processInfo.arguments.contains("-ui-test-cold-quick-capture") {
            QuickCaptureNavigation.requestRecordTab()
        }
        // The same two steps QuickRecordIntent performs after a cold launch.
        if ProcessInfo.processInfo.arguments.contains("-ui-test-cold-action-button") {
            Task { @MainActor in
                _ = await RecordingCoordinator.shared.toggleFromSystem()
                QuickCaptureNavigation.requestRecordTab()
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-ui-test-notification-route") {
            NotificationRouter.shared.open(
                LibraryReference(itemType: "audio", itemId: UITestAPIProtocol.audioID)
            )
        }
        #endif
        configureAppearance()
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-ui-test-reset-recordings") {
            AIProcessingConsentManager.shared.resetForUITesting()
        }
        UITestShareFixture.prepare(arguments: arguments)
        #endif
        // A stored session owns anything captured from here on, including a
        // cold Action Button press and work finishing in a background launch
        // where no scene, and so no ContentView, ever exists.
        // Not during a pending account deletion: a capture claimed by that account
        // now would be removed with its data once the deletion is confirmed.
        if let ownerID = DeviceSessionController.shared.activeUserID,
           !AccountDeletionRecoveryService.shared.hasPendingDeletion {
            aiProcessingConsent.setActiveOwnerID(ownerID)
            recordingCoordinator.setActiveOwnerID(ownerID)
            #if DEBUG
            if arguments.contains("-ui-test-ai-consent") {
                AIProcessingConsentManager.shared.grantForUITesting(ownerID: ownerID)
            }
            #endif
        }
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .tint(Theme.accentText)
                .environment(recordingCoordinator)
                .environment(uploadCoordinator)
                .environment(aiProcessingConsent)
                .environment(deviceSession)
                .environment(NotificationRouter.shared)
                .sheet(isPresented: Binding(
                    get: { aiProcessingConsent.isPresentingDisclosure },
                    set: { if !$0 { aiProcessingConsent.decline() } }
                )) {
                    AIProcessingDisclosureView(manager: aiProcessingConsent)
                }
                .task {
                    uploadCoordinator.processSharedItems()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    uploadCoordinator.processSharedItems()
                    uploadCoordinator.resumePendingWork()
                }
        }
    }

    @ViewBuilder
    private var rootView: some View {
        #if DEBUG
        // Deterministic, authentication-free launch modes let UI tests and
        // manual simulator reviews exercise core screens. Release builds do
        // not contain these branches or their sample library data.
        if ProcessInfo.processInfo.arguments.contains("-ui-test-signed-in") {
            // The real signed-in path through ContentView, with a fixture session.
            ContentView()
        } else if ProcessInfo.processInfo.arguments.contains("-ui-test-onboarding") {
            OnboardingView(isComplete: .constant(false))
        } else if ProcessInfo.processInfo.arguments.contains("-ui-test-welcome") {
            // Force this one test route signed out so an earlier simulator login
            // cannot bypass the welcome screen that App Review needs to discover.
            ContentView(forceSignedOutForUITesting: true)
        } else if ProcessInfo.processInfo.arguments.contains("-ui-test-main") {
            MainView()
        } else if ProcessInfo.processInfo.arguments.contains("-ui-test-library") {
            MainView(previewItems: LibraryListItem.uiTestSamples, initialTab: .library)
        } else if ProcessInfo.processInfo.arguments.contains("-ui-test-library-pagination") {
            MainView(previewItems: LibraryListItem.uiTestPaginationSamples, initialTab: .library)
        } else if ProcessInfo.processInfo.arguments.contains("-ui-test-record") {
            RecordView()
        } else if ProcessInfo.processInfo.arguments.contains("-ui-test-recovery-codes-sheet") {
            RecoveryCodesOneTimePreviewHost()
        } else if ProcessInfo.processInfo.arguments.contains("-ui-test-recovery-sign-in-sheet") {
            RecoveryCodeSignInPreviewHost()
        } else if ProcessInfo.processInfo.arguments.contains("-ui-test-security-status-error") {
            SignInSecurityStatusFailurePreviewHost()
        } else if ProcessInfo.processInfo.arguments.contains("-ui-test-quick-capture") {
            RecordView()
                .task {
                    _ = await recordingCoordinator.toggleFromSystem()
                }
        } else {
            standardRoot
        }
        #else
        standardRoot
        #endif
    }

    @ViewBuilder
    private var standardRoot: some View {
        if hasCompletedOnboarding {
            ContentView()
        } else {
            OnboardingView(isComplete: $hasCompletedOnboarding)
        }
    }

    /// Bars follow the system appearance. Large titles are SF Rounded; the proxies only
    /// take a font, so the title metrics are what keep them following Dynamic Type.
    private func configureAppearance() {
        let navAppearance = UINavigationBarAppearance()
        if #available(iOS 26.0, *) {
            // iOS 26 draws titles behind an opaque bar background, which leaves
            // them in the accessibility tree but blank on screen. Every screen
            // already paints the page background behind a transparent bar.
            navAppearance.configureWithTransparentBackground()
        } else {
            navAppearance.configureWithOpaqueBackground()
            navAppearance.backgroundColor = UIColor.theme("background")
            navAppearance.shadowColor = .clear
        }
        navAppearance.titleTextAttributes = [
            .foregroundColor: UIColor.theme("text"),
            .font: UIFont.displayRounded(.headline, weight: .bold),
        ]
        navAppearance.largeTitleTextAttributes = [
            .foregroundColor: UIColor.theme("text"),
            .font: UIFont.displayRounded(.largeTitle, weight: .heavy),
        ]
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance
    }
}
