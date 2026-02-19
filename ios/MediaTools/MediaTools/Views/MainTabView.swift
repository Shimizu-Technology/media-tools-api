import SwiftUI
import ClerkKit
import ClerkKitUI

struct MainTabView: View {
    @Environment(Clerk.self) private var clerk

    var body: some View {
        TabView {
            Tab("Library", systemImage: "books.vertical") {
                NavigationStack {
                    LibraryView()
                }
            }

            Tab("Transcribe", systemImage: "waveform") {
                NavigationStack {
                    TranscribeView()
                }
            }

            Tab("Record", systemImage: "mic.fill") {
                NavigationStack {
                    RecordView()
                }
            }

            Tab("Collections", systemImage: "folder") {
                NavigationStack {
                    CollectionsListView()
                }
            }

            Tab("Settings", systemImage: "gearshape") {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        .tint(.teal)
    }
}
