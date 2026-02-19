import SwiftUI
import ClerkKit
import ClerkKitUI

struct MainTabView: View {
    @Environment(Clerk.self) private var clerk
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Library", systemImage: "books.vertical", value: 0) {
                NavigationStack {
                    LibraryView()
                }
            }

            Tab("Transcribe", systemImage: "waveform", value: 1) {
                NavigationStack {
                    TranscribeView()
                }
            }

            Tab("Record", systemImage: "mic.fill", value: 2) {
                NavigationStack {
                    RecordView()
                }
            }

            Tab("Collections", systemImage: "folder", value: 3) {
                NavigationStack {
                    CollectionsListView()
                }
            }

            Tab("Settings", systemImage: "gearshape", value: 4) {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        .tint(.teal)
        .task {
            // Request notification permission on first launch
            _ = await NotificationService.requestPermission()
        }
    }
}
