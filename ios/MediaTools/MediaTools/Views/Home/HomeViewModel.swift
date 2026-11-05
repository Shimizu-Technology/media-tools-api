import Foundation

/// Home's own short lists. The Library may be filtered to PDFs at the time, and
/// that must not change what Home calls recent.
@MainActor
@Observable
final class HomeViewModel {
    private(set) var recent: [LibraryListItem] = []
    private(set) var serverFailures: [LibraryListItem] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var loadError: String?

    /// How many failed items the server has in all, which may be more than the page.
    private(set) var failedTotal = 0

    private let previewItems: [LibraryListItem]?
    private let load: () async throws -> LibraryListResponse
    private let loadFailures: () async throws -> LibraryListResponse
    private let now: () -> Date
    private var lastLoadedAt: Date?
    /// A refresh can start while an older one is on the wire. Only the newest may land,
    /// or a list from before a deletion could put the deleted row back.
    private var generation = 0
    private var deletedReferences: Set<LibraryReference> = []

    static let recentLimit = 6

    init(
        service: MediaToolsService = .shared,
        previewItems: [LibraryListItem]? = nil,
        now: @escaping () -> Date = Date.init,
        load: (() async throws -> LibraryListResponse)? = nil,
        loadFailures: (() async throws -> LibraryListResponse)? = nil
    ) {
        self.previewItems = previewItems
        self.now = now
        self.load = load ?? { try await service.listLibraryItems(perPage: Self.recentLimit) }
        self.loadFailures = loadFailures ?? { try await service.listLibraryItems(perPage: 20, status: "failed") }
    }

    var hasActiveItems: Bool {
        recent.contains { ["pending", "processing"].contains($0.status) }
    }

    /// For events that do not prove anything changed, at the Library's own pace.
    func refreshIfStale() async {
        guard !isLoading else { return }
        if let lastLoadedAt,
           now().timeIntervalSince(lastLoadedAt) < LibraryViewModel.minimumAutomaticRefreshInterval {
            return
        }
        await refresh()
    }

    /// A known change: the next automatic refresh runs whatever the throttle says, and a
    /// response already on the wire describes the library from before it, so it can't land.
    func invalidate() {
        lastLoadedAt = nil
        generation += 1
        isLoading = false
    }

    /// Deleted items stay gone from every later response too, however late it arrives.
    func remove(_ references: Set<LibraryReference>) {
        guard !references.isEmpty else { return }
        deletedReferences.formUnion(references.map(\.normalized))
        recent = withoutDeleted(recent)
        serverFailures = withoutDeleted(serverFailures)
    }

    private func withoutDeleted(_ source: [LibraryListItem]) -> [LibraryListItem] {
        source.filter { !deletedReferences.contains($0.reference.normalized) }
    }

    func refresh() async {
        if let previewItems {
            recent = Array(withoutDeleted(previewItems).prefix(Self.recentLimit))
            serverFailures = withoutDeleted(previewItems).filter { $0.status == "failed" }
            failedTotal = serverFailures.count
            hasLoaded = true
            lastLoadedAt = now()
            return
        }
        generation += 1
        let current = generation
        isLoading = true
        defer { if current == generation { isLoading = false } }
        do {
            let latest = try await load()
            guard current == generation, !Task.isCancelled else { return }
            recent = withoutDeleted(latest.data)
            loadError = nil
            hasLoaded = true
            lastLoadedAt = now()
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            loadError = error.localizedDescription
            return
        }
        // Failures are a bonus on top of the list above, so losing this request only
        // leaves the section as it was. The newest page covers the last seven days.
        if let failed = try? await loadFailures() {
            guard current == generation, !Task.isCancelled else { return }
            serverFailures = withoutDeleted(failed.data)
            failedTotal = failed.totalItems
        }
    }
}
