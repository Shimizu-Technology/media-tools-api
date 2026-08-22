import Foundation

enum LibraryMediaFilter: String, CaseIterable, Hashable {
    case all
    case youtube
    case audio
    case pdf

    var title: String {
        switch self {
        case .all: "All"
        case .youtube: "Videos"
        case .audio: "Audio"
        case .pdf: "PDFs"
        }
    }

    var queryValue: String? { self == .all ? nil : rawValue }
}

enum LibraryStatusFilter: String, CaseIterable, Hashable {
    case all
    case active
    case completed
    case failed

    var title: String {
        switch self {
        case .all: "Any status"
        case .active: "In progress"
        case .completed: "Completed"
        case .failed: "Needs attention"
        }
    }

    var queryValue: String? { self == .all ? nil : rawValue }
}

enum LibrarySortOrder: String, CaseIterable, Hashable {
    case newest
    case oldest

    var title: String { self == .newest ? "Newest first" : "Oldest first" }
    var direction: String { self == .newest ? "desc" : "asc" }
}

struct LibraryQuery: Hashable {
    let type: LibraryMediaFilter
    let status: LibraryStatusFilter
    let sort: LibrarySortOrder
    let search: String
}

/// Owns the Library snapshot independently from its navigation destination.
///
/// A detail push temporarily removes `LibraryView` from the active hierarchy,
/// but this model remains owned by the Library tab. Returning therefore reuses
/// the loaded pages, filters, and visible anchor instead of clearing page one.
@MainActor
@Observable
final class LibraryViewModel {
    private(set) var items: [LibraryListItem] = []
    var selectedType: LibraryMediaFilter = .all
    var selectedStatus: LibraryStatusFilter = .all
    var sortOrder: LibrarySortOrder = .newest
    var searchText = ""
    var visibleReference: LibraryReference?
    private(set) var currentPage = 0
    private(set) var totalPages = 0
    private(set) var totalItems = 0
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var loadError: String?

    private let service: MediaToolsService
    private let previewItems: [LibraryListItem]?
    private let pageSize: Int
    private var loadedQuery: LibraryQuery?
    /// Changes whenever a reload supersedes in-flight work. Main-actor code is
    /// re-entrant across `await`, so the query alone cannot identify a stale
    /// pagination response from before a refresh.
    private var reloadGeneration = 0

    init(
        service: MediaToolsService = .shared,
        previewItems: [LibraryListItem]? = nil,
        pageSize: Int = 20
    ) {
        self.service = service
        self.previewItems = previewItems
        self.pageSize = max(1, pageSize)
    }

    var query: LibraryQuery {
        LibraryQuery(
            type: selectedType,
            status: selectedStatus,
            sort: sortOrder,
            search: searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    var hasMore: Bool {
        currentPage > 0 && currentPage < totalPages
    }

    /// Re-entering the Library with the same query is intentionally a no-op.
    /// Pull-to-refresh remains the explicit way to request fresh data.
    func loadIfNeeded(for requestedQuery: LibraryQuery) async {
        guard loadedQuery != requestedQuery else { return }
        await reload(for: requestedQuery, clearExisting: true)
    }

    func refresh() async {
        await reload(for: query, clearExisting: false)
    }

    func retryInitialLoad() async {
        await reload(for: query, clearExisting: true)
    }

    func prefetchIfNeeded(after reference: LibraryReference) async {
        guard shouldPrefetch(after: reference) else { return }
        await loadNextPage(for: query)
    }

    func retryNextPage() async {
        await loadNextPage(for: query)
    }

    func remove(_ references: Set<LibraryReference>) {
        guard !references.isEmpty else { return }
        items.removeAll { references.contains($0.reference) }
        totalItems = max(0, totalItems - references.count)
        if let visibleReference, references.contains(visibleReference) {
            self.visibleReference = items.first?.reference
        }
    }

    static func shouldPrefetch(itemIndex: Int, itemCount: Int, threshold: Int = 5) -> Bool {
        guard itemIndex >= 0, itemIndex < itemCount, itemCount > 0 else { return false }
        return itemIndex >= max(0, itemCount - max(1, threshold))
    }

    private func shouldPrefetch(after reference: LibraryReference) -> Bool {
        guard hasMore,
              !isLoading,
              !isLoadingMore,
              let index = items.firstIndex(where: { $0.reference == reference })
        else { return false }
        return Self.shouldPrefetch(itemIndex: index, itemCount: items.count)
    }

    private func reload(for requestedQuery: LibraryQuery, clearExisting: Bool) async {
        reloadGeneration += 1
        let generation = reloadGeneration
        if clearExisting {
            items = []
            visibleReference = nil
            currentPage = 0
            totalPages = 0
            totalItems = 0
            loadedQuery = nil
        }
        isLoading = true
        loadError = nil
        defer {
            if requestedQuery == query, generation == reloadGeneration {
                isLoading = false
            }
        }

        if let previewItems {
            let filtered = filteredPreviewItems(previewItems, for: requestedQuery)
            guard requestedQuery == query,
                  generation == reloadGeneration,
                  !Task.isCancelled
            else { return }
            let loadedPageCount = clearExisting ? 1 : max(1, currentPage)
            let visibleCount = min(filtered.count, loadedPageCount * pageSize)
            items = Array(filtered.prefix(visibleCount))
            currentPage = filtered.isEmpty ? 0 : max(1, loadedPageCount)
            totalPages = filtered.isEmpty
                ? 0
                : Int(ceil(Double(filtered.count) / Double(pageSize)))
            currentPage = min(currentPage, totalPages)
            totalItems = filtered.count
            loadedQuery = requestedQuery
            return
        }

        do {
            let pagesToReload = clearExisting ? 1 : max(1, currentPage)
            var refreshedItems: [LibraryListItem] = []
            var latestResponse: LibraryListResponse?

            for page in 1...pagesToReload {
                let response = try await listItems(page: page, for: requestedQuery)
                guard !Task.isCancelled,
                      requestedQuery == query,
                      generation == reloadGeneration
                else { return }
                latestResponse = response
                refreshedItems.append(contentsOf: response.data)
                if page >= response.totalPages { break }
            }

            guard let latestResponse,
                  requestedQuery == query,
                  generation == reloadGeneration
            else { return }
            items = deduplicated(refreshedItems)
            currentPage = latestResponse.page
            totalPages = latestResponse.totalPages
            totalItems = latestResponse.totalItems
            loadedQuery = requestedQuery
            updateSpotlightIndex(items, for: requestedQuery)
        } catch {
            guard !Task.isCancelled,
                  requestedQuery == query,
                  generation == reloadGeneration
            else { return }
            loadError = error.localizedDescription
        }
    }

    private func loadNextPage(for requestedQuery: LibraryQuery) async {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        let generation = reloadGeneration
        isLoadingMore = true
        loadError = nil
        defer { isLoadingMore = false }

        if let previewItems {
            let filtered = filteredPreviewItems(previewItems, for: requestedQuery)
            guard requestedQuery == query,
                  generation == reloadGeneration,
                  !Task.isCancelled
            else { return }
            let nextPage = currentPage + 1
            let endIndex = min(filtered.count, nextPage * pageSize)
            items = Array(filtered.prefix(endIndex))
            currentPage = nextPage
            totalPages = Int(ceil(Double(filtered.count) / Double(pageSize)))
            totalItems = filtered.count
            loadedQuery = requestedQuery
            return
        }

        do {
            let response = try await listItems(page: currentPage + 1, for: requestedQuery)
            guard !Task.isCancelled,
                  requestedQuery == query,
                  generation == reloadGeneration
            else { return }
            items = deduplicated(items + response.data)
            currentPage = response.page
            totalPages = response.totalPages
            totalItems = response.totalItems
            loadedQuery = requestedQuery
        } catch {
            guard !Task.isCancelled,
                  requestedQuery == query,
                  generation == reloadGeneration
            else { return }
            loadError = error.localizedDescription
        }
    }

    private func listItems(page: Int, for requestedQuery: LibraryQuery) async throws -> LibraryListResponse {
        try await service.listLibraryItems(
            page: page,
            perPage: pageSize,
            itemType: requestedQuery.type.queryValue,
            status: requestedQuery.status.queryValue,
            search: requestedQuery.search,
            sortDirection: requestedQuery.sort.direction
        )
    }

    private func deduplicated(_ source: [LibraryListItem]) -> [LibraryListItem] {
        var seen: Set<LibraryReference> = []
        return source.filter { seen.insert($0.reference).inserted }
    }

    private func filteredPreviewItems(
        _ source: [LibraryListItem],
        for requestedQuery: LibraryQuery
    ) -> [LibraryListItem] {
        var result = source
        if let type = requestedQuery.type.queryValue {
            result = result.filter { $0.itemType == type }
        }
        if requestedQuery.status == .active {
            result = result.filter { ["pending", "processing"].contains($0.status) }
        } else if let status = requestedQuery.status.queryValue {
            result = result.filter { $0.status == status }
        }
        if !requestedQuery.search.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(requestedQuery.search)
                    || $0.subtitle.localizedCaseInsensitiveContains(requestedQuery.search)
                    || $0.tags.contains { tag in
                        tag.localizedCaseInsensitiveContains(requestedQuery.search)
                    }
            }
        }
        return requestedQuery.sort == .newest ? result : Array(result.reversed())
    }

    private func updateSpotlightIndex(
        _ recentItems: [LibraryListItem],
        for requestedQuery: LibraryQuery
    ) {
        guard requestedQuery.type == .all,
              requestedQuery.status == .all,
              requestedQuery.sort == .newest,
              requestedQuery.search.isEmpty
        else { return }

        SpotlightService.indexLibraryItems(recentItems)
    }
}
