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
        .tint(Theme.brand500)
        .preferredColorScheme(.dark)
        .onAppear {
            let tabAppearance = UITabBarAppearance()
            tabAppearance.configureWithOpaqueBackground()
            tabAppearance.backgroundColor = UIColor(Theme.surface)
            UITabBar.appearance().standardAppearance = tabAppearance
            UITabBar.appearance().scrollEdgeAppearance = tabAppearance

            let navAppearance = UINavigationBarAppearance()
            navAppearance.configureWithOpaqueBackground()
            navAppearance.backgroundColor = UIColor(Theme.surface)
            navAppearance.titleTextAttributes = [.foregroundColor: UIColor(Theme.textPrimary)]
            navAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor(Theme.textPrimary)]
            UINavigationBar.appearance().standardAppearance = navAppearance
            UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        }
        .task {
            _ = await NotificationService.requestPermission()
        }
    }
}
