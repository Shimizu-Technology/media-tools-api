import SwiftUI
import ClerkKit

@main
struct MediaToolsApp: App {
    init() {
        Clerk.configure(publishableKey: Configuration.clerkPublishableKey)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(Clerk.shared)
        }
    }
}
