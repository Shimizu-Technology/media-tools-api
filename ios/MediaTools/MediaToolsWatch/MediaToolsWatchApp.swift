import SwiftUI

@main
struct MediaToolsWatchApp: App {
    @StateObject private var connectivity = WatchConnectivityService.shared
    @StateObject private var recorder = WatchRecorderService()

    var body: some Scene {
        WindowGroup {
            WatchHomeView()
                .environmentObject(connectivity)
                .environmentObject(recorder)
        }
    }
}
