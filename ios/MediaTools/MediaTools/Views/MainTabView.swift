import SwiftUI
struct MainTabView: View {
    private enum TabSelection: Hashable {
        case home
        case library
        case record
        case collections
        case settings
    }

    @State private var selectedTab: TabSelection = .home
    @State private var libraryModel = LibraryViewModel()

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: .home) {
                NavigationStack {
                    WorkspaceView(
                        onOpenLibrary: { selectedTab = .library },
                        onOpenRecord: { selectedTab = .record },
                        onOpenCollections: { selectedTab = .collections }
                    )
                }
            }

            Tab("Library", systemImage: "books.vertical", value: .library) {
                NavigationStack {
                    LibraryView(model: libraryModel)
                }
            }

            Tab("Record", systemImage: "mic.fill", value: .record) {
                NavigationStack {
                    RecordView()
                }
            }

            Tab("Collections", systemImage: "folder", value: .collections) {
                NavigationStack {
                    CollectionsListView()
                }
            }

            Tab("Settings", systemImage: "gearshape", value: .settings) {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        .tint(Theme.brand500)
        .preferredColorScheme(.dark)
        .onOpenURL { url in
            guard url.scheme == "mediatools", url.host == "record" else { return }
            selectedTab = .record
        }
        .onAppear {
            if QuickCaptureNavigation.consumeRecordTabRequest() {
                selectedTab = .record
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaToolsQuickCapture)) { _ in
            // Consume the persisted fallback as well so a later onAppear does
            // not replay a warm-launch navigation request.
            _ = QuickCaptureNavigation.consumeRecordTabRequest()
            selectedTab = .record
        }
    }
}
