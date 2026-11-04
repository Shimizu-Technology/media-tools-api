import SwiftUI

/// Everything is one navigation stack over the Library. Pushing rather than
/// presenting keeps the one presentation that can arrive at any moment, the AI
/// consent sheet at the app root, from colliding with a screen already on top.
enum AppRoute: Hashable {
    case item(LibraryReference)
    case record
    case importAudio
    case settings
    case collections
    case collection(String)
    case addLink
    case addPDF
}

struct MainView: View {
    @State private var path: [AppRoute] = []
    @State private var libraryModel: LibraryViewModel
    @Environment(NotificationRouter.self) private var notificationRouter
    private let previewItems: [LibraryListItem]?

    /// `previewItems` swaps in sample rows for the Debug launch modes.
    init(previewItems: [LibraryListItem]? = nil) {
        self.previewItems = previewItems
        _libraryModel = State(initialValue: LibraryViewModel(previewItems: previewItems))
    }

    var body: some View {
        NavigationStack(path: $path) {
            LibraryView(model: libraryModel, previewItems: previewItems, path: $path)
                .navigationDestination(for: AppRoute.self) { route in
                    AppRouteDestination(route: route, previewItems: previewItems)
                }
        }
        .onOpenURL { url in
            // The Live Activity's deep link.
            guard url.scheme == "mediatools", url.host == "record" else { return }
            showRecorder()
        }
        .onAppear {
            if QuickCaptureNavigation.consumeRecordTabRequest() {
                // A cold Action Button press lands on the recorder, with no slide
                // across a Library the person never asked to see.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { showRecorder() }
            }
            openPendingNotificationRoute()
        }
        .onChange(of: notificationRouter.pendingReference) { _, _ in
            openPendingNotificationRoute()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaToolsQuickCapture)) { _ in
            // Consume the persisted fallback as well so a later onAppear does
            // not replay a warm-launch navigation request.
            _ = QuickCaptureNavigation.consumeRecordTabRequest()
            showRecorder()
        }
        .onChange(of: path) { previous, current in
            // A detail screen may have renamed, archived, or finished the item.
            guard current.count < previous.count,
                  case .item = previous.last
            else { return }
            Task { await libraryModel.refresh() }
        }
    }

    /// Keeps your place: Back from the recorder returns to whatever was open.
    private func showRecorder() {
        if let existing = path.lastIndex(of: .record) ?? path.lastIndex(of: .importAudio) {
            path.removeSubrange((existing + 1)...)
        } else {
            path.append(.record)
        }
    }

    private func openPendingNotificationRoute() {
        guard let reference = notificationRouter.consume() else { return }
        path = [.item(reference)]
    }
}

struct AppRouteDestination: View {
    let route: AppRoute
    var previewItems: [LibraryListItem]?

    var body: some View {
        switch route {
        case .item(let reference):
            LibraryDetailLoader(
                reference: reference,
                previewTitle: previewItems?.first { $0.reference == reference }?.displayTitle
            )
        case .record:
            RecordView()
        case .importAudio:
            RecordView(opensImporterOnAppear: true)
        case .settings:
            SettingsView()
        case .collections:
            CollectionsListView()
        case .collection(let id):
            CollectionDetailView(collectionId: id)
        case .addLink:
            TranscribeView()
        case .addPDF:
            PDFUploadView()
        }
    }
}
