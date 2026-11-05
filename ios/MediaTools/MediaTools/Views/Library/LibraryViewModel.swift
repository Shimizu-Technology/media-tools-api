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

struct LibraryCollectionFilter: Hashable {
    let id: String
    let name: String
}

struct LibraryQuery: Hashable {
    let type: LibraryMediaFilter
    let status: LibraryStatusFilter
    let sort: LibrarySortOrder
    let search: String
    var archivedOnly = false
    var favoriteOnly = false
}

/// The Library's one row of filters. Status, sort, and collection sit in its filter
/// menu, because most people never need them.
enum LibraryChip: String, CaseIterable, Hashable, Identifiable {
    case all
    case recordings
    case links
    case pdfs
    case starred
    case archived

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .recordings: "Recordings"
        case .links: "Links"
        case .pdfs: "PDFs"
        case .starred: "Starred"
        case .archived: "Archived"
        }
    }
}

/// What the Library shows of the work still on this device under its filters, and how
/// much that needs a person those filters have put out of view. Home always lists it.
struct LibraryDeviceWork {
    struct Filters: Equatable {
        var type: LibraryMediaFilter = .all
        var status: LibraryStatusFilter = .all
        var isSearching = false
        var isCollection = false
        var isArchived = false
        var isStarred = false

        /// None of these has on-device work in it: search reads the server's text, and
        /// nothing on this device is in a collection, starred, or archived yet.
        var excludesAllDeviceWork: Bool {
            isSearching || isCollection || isArchived || isStarred
        }
    }

    let visibleRecordings: [LocalRecording]
    let visibleShares: [ShareInboxStore.Item]
    let hiddenNeedingAction: Int

    init(
        recordings: [LocalRecording],
        shares: [ShareInboxStore.Item],
        filters: Filters,
        autoTranscribeWillSend: Bool
    ) {
        func typeMatches(_ kind: ShareInboxStore.Kind) -> Bool {
            switch filters.type {
            case .all: true
            case .audio: kind == .audio
            case .youtube: kind == .link
            case .pdf: kind == .pdf
            }
        }
        func shows(_ recording: LocalRecording) -> Bool {
            guard !filters.excludesAllDeviceWork, typeMatches(.audio) else { return false }
            switch filters.status {
            case .all, .active: return true
            // "Needs attention" is exactly this work, and nothing still on its way.
            case .failed: return recording.needsPerson(autoTranscribeWillSend: autoTranscribeWillSend)
            case .completed: return false
            }
        }
        // Every share here needs attention by definition, so only "Completed" rules it out.
        func shows(_ share: ShareInboxStore.Item) -> Bool {
            !filters.excludesAllDeviceWork && typeMatches(share.resolvedKind) && filters.status != .completed
        }
        visibleRecordings = recordings.filter(shows)
        visibleShares = shares.filter(shows)
        hiddenNeedingAction = recordings.filter {
            $0.needsPerson(autoTranscribeWillSend: autoTranscribeWillSend) && !shows($0)
        }.count + shares.filter { !shows($0) }.count
    }
}

/// Owns the Library snapshot independently from its navigation destination.
///
/// A detail push temporarily removes `LibraryView` from the active hierarchy,
/// but this model remains owned by `MainView`. Returning therefore reuses
/// the loaded pages, filters, and visible anchor instead of clearing page one.
@MainActor
@Observable
final class LibraryViewModel {
    private(set) var items: [LibraryListItem] = []
    var selectedType: LibraryMediaFilter = .all
    var selectedStatus: LibraryStatusFilter = .all
    var sortOrder: LibrarySortOrder = .newest
    var searchText = ""
    var showsArchived = false
    var showsFavoritesOnly = false
    var visibleReference: LibraryReference?
    /// Collections are a filter over the Library. The server's list endpoint has no
    /// collection parameter, so a chosen collection shows its own item list.
    var selectedCollection: LibraryCollectionFilter?
    private(set) var collectionItems: [CollectionItem] = []
    private(set) var isLoadingCollection = false
    private(set) var collectionError: String?
    private(set) var currentPage = 0
    private(set) var totalPages = 0
    private(set) var totalItems = 0
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var loadError: String?

    private let service: MediaToolsService
    private let previewItems: [LibraryListItem]?
    private let pageSize: Int
    private let loadPage: ((Int, LibraryQuery) async throws -> LibraryListResponse)?
    private var deletedReferences: Set<LibraryReference> = []
    private var loadedQuery: LibraryQuery?
    /// Changes whenever a reload supersedes in-flight work. Main-actor code is
    /// re-entrant across `await`, so the query alone cannot identify a stale
    /// pagination response from before a refresh.
    private var reloadGeneration = 0
    /// Separately owns the pagination loading indicator. A refresh invalidates
    /// an older page request immediately, while that request's eventual defer
    /// must not clear the indicator for a newer page request.
    private var paginationGeneration = 0
    private var lastLoadedAt: Date?
    private let now: () -> Date

    /// Separates tab switches and foregrounding from each other enough that
    /// neither wakes the database twice for one glance at the Library.
    static let minimumAutomaticRefreshInterval: TimeInterval = 15

    init(
        service: MediaToolsService = .shared,
        previewItems: [LibraryListItem]? = nil,
        pageSize: Int = 20,
        now: @escaping () -> Date = Date.init,
        loadPage: ((Int, LibraryQuery) async throws -> LibraryListResponse)? = nil
    ) {
        self.now = now
        self.loadPage = loadPage
        self.service = service
        self.previewItems = previewItems
        self.pageSize = max(1, pageSize)
    }

    var query: LibraryQuery {
        LibraryQuery(
            type: selectedType,
            status: selectedStatus,
            sort: sortOrder,
            search: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            archivedOnly: showsArchived,
            favoriteOnly: showsFavoritesOnly
        )
    }

    var selectedChip: LibraryChip {
        get {
            if showsArchived { return .archived }
            if showsFavoritesOnly { return .starred }
            switch selectedType {
            case .all: return .all
            case .audio: return .recordings
            case .youtube: return .links
            case .pdf: return .pdfs
            }
        }
        set {
            selectedCollection = nil
            showsArchived = newValue == .archived
            showsFavoritesOnly = newValue == .starred
            switch newValue {
            case .all, .starred, .archived: selectedType = .all
            case .recordings: selectedType = .audio
            case .links: selectedType = .youtube
            case .pdfs: selectedType = .pdf
            }
        }
    }

    var hasMore: Bool {
        currentPage > 0 && currentPage < totalPages
    }

    /// Re-entering the Library with the same query keeps its loaded pages and
    /// scroll position. `refreshIfStale` is what keeps those pages current.
    func loadIfNeeded(for requestedQuery: LibraryQuery) async {
        guard loadedQuery != requestedQuery else { return }
        await reload(for: requestedQuery, clearExisting: true)
    }

    func refresh() async {
        await reload(for: query, clearExisting: false)
    }

    /// For events that do not prove anything changed: tab appearance and
    /// foregrounding. Known changes call `refresh()` directly.
    func refreshIfStale() async {
        guard loadedQuery == query, !isLoading else { return }
        if let lastLoadedAt,
           now().timeIntervalSince(lastLoadedAt) < Self.minimumAutomaticRefreshInterval {
            return
        }
        await refresh()
    }

    var hasActiveItems: Bool {
        items.contains { ["pending", "processing"].contains($0.status) }
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

    /// A collection that has gone away falls back to its error, with the rest of the
    /// Library one filter change away.
    func loadSelectedCollection() async {
        guard let filter = selectedCollection else {
            collectionItems = []
            collectionError = nil
            return
        }
        isLoadingCollection = true
        collectionError = nil
        defer { isLoadingCollection = false }
        do {
            let collection = try await service.getCollection(filter.id)
            guard selectedCollection == filter, !Task.isCancelled else { return }
            collectionItems = withoutDeleted(collection.items ?? [])
        } catch {
            guard selectedCollection == filter, !Task.isCancelled else { return }
            collectionItems = []
            collectionError = error.localizedDescription
        }
    }

    /// A known change: the next automatic refresh runs whatever the throttle says, and a
    /// response already on the wire describes the library from before it, so it can't land.
    func invalidate() {
        lastLoadedAt = nil
        reloadGeneration += 1
        paginationGeneration += 1
        isLoading = false
        isLoadingMore = false
    }

    var deviceWorkFilters: LibraryDeviceWork.Filters {
        LibraryDeviceWork.Filters(
            type: selectedType,
            status: selectedStatus,
            isSearching: !query.search.isEmpty,
            isCollection: selectedCollection != nil,
            isArchived: showsArchived,
            isStarred: showsFavoritesOnly
        )
    }

    /// Clears whatever is hiding on-device work, and nothing else: the sort stays.
    func clearFiltersForDeviceWork() {
        selectedChip = .all
        selectedStatus = .all
        searchText = ""
    }

    /// Deleted items stay gone from every later response too, however late it arrives.
    func remove(_ references: Set<LibraryReference>) {
        guard !references.isEmpty else { return }
        deletedReferences.formUnion(references.map(\.normalized))
        // Safe to repeat: the count falls only for rows that were actually here.
        let before = items.count
        items = withoutDeleted(items)
        totalItems = max(0, totalItems - (before - items.count))
        collectionItems = withoutDeleted(collectionItems)
        if let visibleReference, deletedReferences.contains(visibleReference.normalized) {
            self.visibleReference = items.first?.reference
        }
    }

    private func withoutDeleted(_ source: [LibraryListItem]) -> [LibraryListItem] {
        source.filter { !deletedReferences.contains($0.reference.normalized) }
    }

    private func withoutDeleted(_ source: [CollectionItem]) -> [CollectionItem] {
        source.filter {
            !deletedReferences.contains(LibraryReference(itemType: $0.itemType, itemId: $0.itemId).normalized)
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
        paginationGeneration += 1
        isLoadingMore = false
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
            lastLoadedAt = now()
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
            lastLoadedAt = now()
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
        paginationGeneration += 1
        let pageGeneration = paginationGeneration
        isLoadingMore = true
        loadError = nil
        defer {
            if pageGeneration == paginationGeneration {
                isLoadingMore = false
            }
        }

        if let previewItems {
            let filtered = filteredPreviewItems(previewItems, for: requestedQuery)
            guard requestedQuery == query,
                  generation == reloadGeneration,
                  pageGeneration == paginationGeneration,
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
                  generation == reloadGeneration,
                  pageGeneration == paginationGeneration
            else { return }
            items = deduplicated(items + response.data)
            currentPage = response.page
            totalPages = response.totalPages
            totalItems = response.totalItems
            loadedQuery = requestedQuery
        } catch {
            guard !Task.isCancelled,
                  requestedQuery == query,
                  generation == reloadGeneration,
                  pageGeneration == paginationGeneration
            else { return }
            loadError = error.localizedDescription
        }
    }

    private func listItems(page: Int, for requestedQuery: LibraryQuery) async throws -> LibraryListResponse {
        if let loadPage { return try await loadPage(page, requestedQuery) }
        return try await service.listLibraryItems(
            page: page,
            perPage: pageSize,
            itemType: requestedQuery.type.queryValue,
            status: requestedQuery.status.queryValue,
            search: requestedQuery.search,
            sortDirection: requestedQuery.sort.direction,
            archivedOnly: requestedQuery.archivedOnly,
            favoriteOnly: requestedQuery.favoriteOnly
        )
    }

    private func deduplicated(_ source: [LibraryListItem]) -> [LibraryListItem] {
        var seen: Set<LibraryReference> = []
        return withoutDeleted(source).filter { seen.insert($0.reference).inserted }
    }

    private func filteredPreviewItems(
        _ source: [LibraryListItem],
        for requestedQuery: LibraryQuery
    ) -> [LibraryListItem] {
        var result = withoutDeleted(source).filter { $0.archived == requestedQuery.archivedOnly }
        if requestedQuery.favoriteOnly {
            result = result.filter(\.favorite)
        }
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
              requestedQuery.search.isEmpty,
              !requestedQuery.archivedOnly,
              !requestedQuery.favoriteOnly
        else { return }

        SpotlightService.indexLibraryItems(recentItems)
    }
}
