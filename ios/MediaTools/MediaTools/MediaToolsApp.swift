import SwiftUI
import ClerkKit

@main
struct MediaToolsApp: App {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    init() {
        Clerk.configure(publishableKey: Configuration.clerkPublishableKey)
    }

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                ContentView()
                    .environment(Clerk.shared)
            } else {
                OnboardingView(isComplete: $hasCompletedOnboarding)
            }
        }
    }
}
