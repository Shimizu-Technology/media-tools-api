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

    private let service: MediaToolsService
    private let previewItems: [LibraryListItem]?
    private let now: () -> Date
    private var lastLoadedAt: Date?

    static let recentLimit = 6

    init(
        service: MediaToolsService = .shared,
        previewItems: [LibraryListItem]? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.service = service
        self.previewItems = previewItems
        self.now = now
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

    func refresh() async {
        if let previewItems {
            recent = Array(previewItems.prefix(Self.recentLimit))
            serverFailures = previewItems.filter { $0.status == "failed" }
            hasLoaded = true
            lastLoadedAt = now()
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let latest = try await service.listLibraryItems(perPage: Self.recentLimit)
            guard !Task.isCancelled else { return }
            recent = latest.data
            loadError = nil
            hasLoaded = true
            lastLoadedAt = now()
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
            return
        }
        // Failures are a bonus on top of the list above, so losing this request only
        // leaves the section as it was. The newest page covers the last seven days.
        if let failed = try? await service.listLibraryItems(perPage: 20, status: "failed") {
            guard !Task.isCancelled else { return }
            serverFailures = failed.data
        }
    }
}
