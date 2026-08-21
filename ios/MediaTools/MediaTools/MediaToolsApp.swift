import SwiftUI
import ClerkKit

@main
struct MediaToolsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var recordingCoordinator = RecordingCoordinator.shared
    @State private var uploadCoordinator = RecordingUploadCoordinator.shared

    init() {
        Clerk.configure(publishableKey: Configuration.clerkPublishableKey)
        MediaToolsAppShortcuts.updateAppShortcutParameters()
        #if DEBUG
        // Exercise the real cold-launch handoff in UI tests: publish the route
        // before MainTabView exists, just as an Action Button intent can.
        if ProcessInfo.processInfo.arguments.contains("-ui-test-cold-quick-capture") {
            QuickCaptureNavigation.requestRecordTab()
        }
        #endif
        configureAppearance()
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .environment(recordingCoordinator)
                .environment(uploadCoordinator)
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
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
        if ProcessInfo.processInfo.arguments.contains("-ui-test-onboarding") {
            OnboardingView(isComplete: .constant(false))
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
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = UIColor(Theme.surface)
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
