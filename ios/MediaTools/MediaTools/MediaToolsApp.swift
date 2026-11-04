import SwiftUI
import ClerkKit

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
        Clerk.configure(publishableKey: Configuration.clerkPublishableKey)
        MediaToolsAppShortcuts.updateAppShortcutParameters()
        #if DEBUG
        // Exercise the real cold-launch handoff in UI tests: publish the route
        // before MainTabView exists, just as an Action Button intent can.
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
                .environment(Clerk.shared)
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.arguments.contains("-ui-test-onboarding") {
            OnboardingView(isComplete: .constant(false))
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.arguments.contains("-ui-test-welcome") {
            // Clerk persists sessions in the Keychain. Force this one test
            // route signed out so an earlier simulator login cannot bypass
            // the welcome screen that App Review needs to discover.
            ContentView(forceSignedOutForUITesting: true)
                .environment(Clerk.shared)
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.arguments.contains("-ui-test-main") {
            MainTabView()
                .environment(Clerk.shared)
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.arguments.contains("-ui-test-library") {
            NavigationStack {
                LibraryView(previewItems: LibraryListItem.uiTestSamples)
            }
            .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.arguments.contains("-ui-test-library-pagination") {
            NavigationStack {
                LibraryView(previewItems: LibraryListItem.uiTestPaginationSamples)
            }
            .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.arguments.contains("-ui-test-record") {
            NavigationStack {
                RecordView()
            }
            .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.arguments.contains("-ui-test-recovery-codes-sheet") {
            RecoveryCodesOneTimePreviewHost()
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.arguments.contains("-ui-test-recovery-sign-in-sheet") {
            RecoveryCodeSignInPreviewHost()
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.arguments.contains("-ui-test-security-status-error") {
            SignInSecurityStatusFailurePreviewHost()
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.arguments.contains("-ui-test-clerk-migration") {
            ClerkMigrationPreviewHost()
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.arguments.contains("-ui-test-quick-capture") {
            NavigationStack {
                RecordView()
            }
            .preferredColorScheme(.dark)
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
                .environment(Clerk.shared)
                .preferredColorScheme(.dark)
        } else {
            OnboardingView(isComplete: $hasCompletedOnboarding)
                .preferredColorScheme(.dark)
        }
    }

    /// Force dark mode and tint the navigation/tab bars to match the theme.
    private func configureAppearance() {
        // Navigation bar
        let navAppearance = UINavigationBarAppearance()
        if #available(iOS 26.0, *) {
            // iOS 26 draws titles behind an opaque bar background, which leaves
            // them in the accessibility tree but blank on screen. Every screen
            // already paints Theme.surface behind a transparent bar.
            navAppearance.configureWithTransparentBackground()
        } else {
            navAppearance.configureWithOpaqueBackground()
            navAppearance.backgroundColor = UIColor(Theme.surface)
        }
        navAppearance.titleTextAttributes = [.foregroundColor: UIColor(Theme.textPrimary)]
        navAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor(Theme.textPrimary)]
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().tintColor = UIColor(Theme.brand500)

        // Tab bar
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = UIColor(Theme.surfaceElevated)
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance
        UITabBar.appearance().tintColor = UIColor(Theme.brand500)
        UITabBar.appearance().unselectedItemTintColor = UIColor(Theme.textMuted)

        // Table/List background
        UITableView.appearance().backgroundColor = UIColor(Theme.surface)
    }
}
