import SwiftUI
import ClerkKit

@main
struct MediaToolsApp: App {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    init() {
        Clerk.configure(publishableKey: Configuration.clerkPublishableKey)
        configureAppearance()
    }

    var body: some Scene {
        WindowGroup {
            rootView
        }
    }

    @ViewBuilder
    private var rootView: some View {
        #if DEBUG
        // A deterministic, authentication-free launch mode lets UI tests and manual
        // simulator reviews exercise recording without authenticating. Release
        // builds do not contain this branch.
        if ProcessInfo.processInfo.arguments.contains("-ui-test-record") {
            NavigationStack {
                RecordView()
            }
            .preferredColorScheme(.dark)
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
