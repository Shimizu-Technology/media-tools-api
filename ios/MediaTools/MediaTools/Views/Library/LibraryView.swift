import SwiftUI

struct LibraryView: View {
    @State private var items: [LibraryListItem] = []
    @State private var selectedType: MediaFilter = .all
    @State private var selectedStatus: StatusFilter = .all
    @State private var sortOrder: SortOrder = .newest
    @State private var searchText = ""
    @State private var currentPage = 0
    @State private var totalPages = 0
    @State private var totalItems = 0
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var loadError: String?
    @State private var operationError: String?
    @State private var isSelecting = false
    @State private var selectedReferences: Set<LibraryReference> = []
    @State private var pendingDeletion: [LibraryReference] = []
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var collectionTarget: LibraryReference?

    private let service = MediaToolsService.shared
    private let previewItems: [LibraryListItem]?

    init(previewItems: [LibraryListItem]? = nil) {
        self.previewItems = previewItems
    }

    private enum MediaFilter: String, CaseIterable, Hashable {
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

    private enum StatusFilter: String, CaseIterable, Hashable {
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

    private enum SortOrder: String, CaseIterable, Hashable {
        case newest
        case oldest

        var title: String { self == .newest ? "Newest first" : "Oldest first" }
        var direction: String { self == .newest ? "desc" : "asc" }
    }

    private struct Query: Hashable {
        let type: MediaFilter
        let status: StatusFilter
        let sort: SortOrder
        let search: String
    }

    private var query: Query {
        Query(
            type: selectedType,
            status: selectedStatus,
            sort: sortOrder,
            search: searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private var hasMore: Bool {
        currentPage > 0 && currentPage < totalPages
    }

    var body: some View {
        VStack(spacing: 0) {
            mediaFilterBar
            libraryList
        }
        .background(Theme.surface)
        .navigationTitle("Library")
        .searchable(text: $searchText, prompt: "Search all media")
        .toolbar { libraryToolbar }
        .safeAreaInset(edge: .bottom) { selectionBar }
        .navigationDestination(for: LibraryReference.self) { reference in
            LibraryDetailLoader(reference: reference)
        }
        .navigationDestination(for: String.self) { value in
            if value == "pdf-upload" {
                PDFUploadView()
            }
        }
        .sheet(item: $collectionTarget) { reference in
            AddToCollectionSheet(
                itemType: reference.collectionItemType,
                itemId: reference.itemId,
                onDismiss: { collectionTarget = nil }
            )
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await deletePendingItems() }
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = []
            }
        } message: {
            Text("This permanently removes the selected content and cannot be undone.")
        }
        .task(id: query) {
            let requestedQuery = query
            if !requestedQuery.search.isEmpty {
                do {
                    try await Task.sleep(for: .milliseconds(300))
                } catch {
                    return
                }
            }
            await reload(for: requestedQuery, clearExisting: true)
        }
    }

    private var mediaFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MediaFilter.allCases, id: \.self) { filter in
                    Button {
                        withAnimation(Theme.springSnappy) {
                            selectedType = filter
                            leaveSelectionMode()
                        }
                    } label: {
                        Text(filter.title)
                            .font(Theme.body(13, weight: .medium))
                            .foregroundStyle(selectedType == filter ? Color.white : Theme.textSecondary)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(selectedType == filter ? Theme.brand500 : Theme.surfaceElevated)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedType == filter ? .isSelected : [])
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Theme.surface)
    }

    private var libraryList: some View {
        List {
            if let operationError {
                dismissibleErrorRow(operationError)
            }

            if isLoading && items.isEmpty {
                loadingRow
            } else if let loadError, items.isEmpty {
                errorRow(loadError)
            } else if items.isEmpty {
                emptyRow
            } else {
                if selectedStatus != .all || sortOrder != .newest || !query.search.isEmpty {
                    filterSummaryRow
                }

                ForEach(items) { item in
                    libraryRow(item)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                if hasMore {
                    loadMoreRow
                        .task {
                            await loadNextPage(for: query)
                        }
                } else if totalItems > 0 {
                    Text("\(totalItems) item\(totalItems == 1 ? "" : "s")")
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await reload(for: query, clearExisting: false)
        }
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { leaveSelectionMode() }
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Section("Status") {
                    ForEach(StatusFilter.allCases, id: \.self) { filter in
                        Button {
                            selectedStatus = filter
                            leaveSelectionMode()
                        } label: {
                            if selectedStatus == filter {
                                Label(filter.title, systemImage: "checkmark")
                            } else {
                                Text(filter.title)
                            }
                        }
                    }
                }

                Section("Sort") {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        Button {
                            sortOrder = order
                            leaveSelectionMode()
                        } label: {
                            if sortOrder == order {
                                Label(order.title, systemImage: "checkmark")
                            } else {
                                Text(order.title)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        withAnimation(Theme.springSnappy) {
                            isSelecting = true
                        }
                    } label: {
                        Label("Select Items", systemImage: "checkmark.circle")
                    }
                    .disabled(items.isEmpty || isSelecting)

                    NavigationLink(value: "pdf-upload") {
                        Label("Upload PDF", systemImage: "doc.badge.plus")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Library actions")
        }
    }

    @ViewBuilder
    private func libraryRow(_ item: LibraryListItem) -> some View {
        if isSelecting {
            Button {
                toggleSelection(item.reference)
            } label: {
                LibrarySummaryRow(
                    item: item,
                    selectionState: selectedReferences.contains(item.reference)
                )
                .cardStyle(padding: 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(selectedReferences.contains(item.reference) ? "Deselect" : "Select") \(item.title)")
        } else {
            NavigationLink(value: item.reference) {
                LibrarySummaryRow(item: item, selectionState: nil)
                    .cardStyle(padding: 12)
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    requestDeletion([item.reference])
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    collectionTarget = item.reference
                } label: {
                    Label("Collect", systemImage: "folder.badge.plus")
                }
                .tint(Theme.brand500)
            }
        }
    }

    private var loadingRow: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(Theme.brand500)
            Text("Loading your library…")
                .font(Theme.body(14))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
    }

    private func errorRow(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn’t Load Library", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") {
                Task { await reload(for: query, clearExisting: true) }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.brand500)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var emptyRow: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: query.search.isEmpty ? "tray" : "magnifyingglass")
        } description: {
            Text(emptyDescription)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var emptyTitle: String {
        if !query.search.isEmpty { return "No Results" }
        if selectedStatus != .all { return "No Matching Items" }
        return "Your Library Is Ready"
    }

    private var emptyDescription: String {
        if !query.search.isEmpty {
            return "Try a different title, transcript phrase, summary, or tag."
        }
        if selectedStatus != .all {
            return "Change the status filter to see more of your library."
        }
        return "Transcribe a video, record audio, or upload a PDF to add your first item."
    }

    private var filterSummaryRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(Theme.brand400)
            Text(filterSummary)
                .font(Theme.caption())
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            if selectedStatus != .all || sortOrder != .newest {
                Button("Reset") {
                    selectedStatus = .all
                    sortOrder = .newest
                }
                .font(Theme.caption())
                .foregroundStyle(Theme.brand400)
                .frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 4)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var filterSummary: String {
        var parts: [String] = []
        if !query.search.isEmpty { parts.append("Results for “\(query.search)”") }
        if selectedStatus != .all { parts.append(selectedStatus.title) }
        if sortOrder != .newest { parts.append(sortOrder.title) }
        return parts.joined(separator: " · ")
    }

    private func dismissibleErrorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
            Text(message)
                .font(Theme.caption())
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Button {
                operationError = nil
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Dismiss error")
        }
        .padding(12)
        .background(Theme.warning.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var loadMoreRow: some View {
        HStack {
            Spacer()
            if isLoadingMore {
                ProgressView()
                    .tint(Theme.brand500)
            } else if loadError != nil {
                Button("Load More") {
                    Task { await loadNextPage(for: query) }
                }
                .frame(minWidth: 120, minHeight: 44)
            }
            Spacer()
        }
        .frame(minHeight: 52)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var selectionBar: some View {
        if isSelecting {
            HStack(spacing: 12) {
                Text("\(selectedReferences.count) selected")
                    .font(Theme.body(14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button(role: .destructive) {
                    requestDeletion(Array(selectedReferences))
                } label: {
                    if isDeleting {
                        ProgressView()
                            .tint(Theme.error)
                    } else {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .buttonStyle(.bordered)
                .tint(Theme.error)
                .frame(minHeight: 44)
                .disabled(selectedReferences.isEmpty || isDeleting)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) {
                Divider().overlay(Theme.borderSubtle)
            }
        }
    }

    private var deletionTitle: String {
        let count = pendingDeletion.count
        return count == 1 ? "Delete This Item?" : "Delete \(count) Items?"
    }

    private func toggleSelection(_ reference: LibraryReference) {
        if selectedReferences.contains(reference) {
            selectedReferences.remove(reference)
        } else {
            selectedReferences.insert(reference)
        }
        Haptics.light()
    }

    private func leaveSelectionMode() {
        isSelecting = false
        selectedReferences.removeAll()
    }

    private func requestDeletion(_ references: [LibraryReference]) {
        guard !references.isEmpty else { return }
        pendingDeletion = references.sorted { $0.id < $1.id }
        showDeleteConfirmation = true
    }

    private func reload(for requestedQuery: Query, clearExisting: Bool) async {
        if clearExisting {
            items = []
            currentPage = 0
            totalPages = 0
            totalItems = 0
            isSelecting = false
            selectedReferences.removeAll()
        }
        isLoading = true
        loadError = nil
        defer {
            if requestedQuery == query {
                isLoading = false
            }
        }

        if let previewItems {
            let filtered = filteredPreviewItems(previewItems, for: requestedQuery)
            guard requestedQuery == query else { return }
            items = filtered
            currentPage = 1
            totalPages = filtered.isEmpty ? 0 : 1
            totalItems = filtered.count
            return
        }

        do {
            let response = try await service.listLibraryItems(
                page: 1,
                itemType: requestedQuery.type.queryValue,
                status: requestedQuery.status.queryValue,
                search: requestedQuery.search,
                sortDirection: requestedQuery.sort.direction
            )
            guard !Task.isCancelled, requestedQuery == query else { return }
            items = response.data
            currentPage = response.page
            totalPages = response.totalPages
            totalItems = response.totalItems
            updateSystemIntegrations(response.data, for: requestedQuery)
        } catch {
            guard !Task.isCancelled, requestedQuery == query else { return }
            loadError = error.localizedDescription
        }
    }

    private func loadNextPage(for requestedQuery: Query) async {
        guard hasMore, !isLoadingMore, previewItems == nil else { return }
        isLoadingMore = true
        loadError = nil
        defer { isLoadingMore = false }

        do {
            let response = try await service.listLibraryItems(
                page: currentPage + 1,
                itemType: requestedQuery.type.queryValue,
                status: requestedQuery.status.queryValue,
                search: requestedQuery.search,
                sortDirection: requestedQuery.sort.direction
            )
            guard requestedQuery == query else { return }
            let known = Set(items.map(\.reference))
            items.append(contentsOf: response.data.filter { !known.contains($0.reference) })
            currentPage = response.page
            totalPages = response.totalPages
            totalItems = response.totalItems
        } catch {
            guard requestedQuery == query else { return }
            loadError = error.localizedDescription
        }
    }

    private func filteredPreviewItems(_ source: [LibraryListItem], for requestedQuery: Query) -> [LibraryListItem] {
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

    private func updateSystemIntegrations(_ recentItems: [LibraryListItem], for requestedQuery: Query) {
        guard requestedQuery.type == .all,
              requestedQuery.status == .all,
              requestedQuery.sort == .newest,
              requestedQuery.search.isEmpty else { return }

        SpotlightService.indexLibraryItems(recentItems)
        WidgetService.updateRecentItems(recentItems)
    }

    private func deletePendingItems() async {
        let references = pendingDeletion
        guard !references.isEmpty else { return }
        showDeleteConfirmation = false
        isDeleting = true
        operationError = nil
        defer {
            isDeleting = false
            pendingDeletion = []
        }

        if previewItems != nil {
            let deleted = Set(references)
            items.removeAll { deleted.contains($0.reference) }
            totalItems = items.count
            leaveSelectionMode()
            return
        }

        var deleted: Set<LibraryReference> = []
        var failed: [LibraryReference] = []
        for reference in references {
            do {
                try await service.deleteLibraryItem(reference)
                deleted.insert(reference)
            } catch {
                failed.append(reference)
            }
        }

        items.removeAll { deleted.contains($0.reference) }
        totalItems = max(0, totalItems - deleted.count)
        SpotlightService.removeLibraryItems(Array(deleted))
        updateSystemIntegrations(Array(items.prefix(20)), for: query)
        selectedReferences = Set(failed)
        if failed.isEmpty {
            leaveSelectionMode()
            Haptics.success()
            await reload(for: query, clearExisting: false)
        } else {
            isSelecting = true
            operationError = "\(failed.count) item\(failed.count == 1 ? "" : "s") couldn’t be deleted. The failed selection was kept so you can try again."
            Haptics.error()
        }
    }
}

struct LibrarySummaryRow: View {
    let item: LibraryListItem
    let selectionState: Bool?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(iconColor.opacity(0.14))
                Image(systemName: iconName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)

                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    StatusBadge(status: item.status)
                    if let detail = detailText {
                        Text(detail)
                            .font(Theme.caption())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if item.favorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.warning)
                            .accessibilityLabel("Favorite")
                    }
                }
            }

            Spacer(minLength: 4)

            if let selectionState {
                Image(systemName: selectionState ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selectionState ? Theme.brand400 : Theme.textMuted)
            } else if ["pending", "processing"].contains(item.status) {
                ProgressView()
                    .tint(Theme.brand400)
                    .accessibilityLabel("Processing")
            }
        }
        .frame(minHeight: 58)
        .contentShape(Rectangle())
    }

    private var iconName: String {
        switch item.itemType {
        case "youtube": "play.rectangle.fill"
        case "audio": "waveform"
        case "pdf": "doc.fill"
        default: "doc"
        }
    }

    private var iconColor: Color {
        switch item.itemType {
        case "youtube": Theme.videoColor
        case "audio": Theme.audioColor
        case "pdf": Theme.pdfColor
        default: Theme.brand400
        }
    }

    private var detailText: String? {
        switch item.itemType {
        case "audio" where item.duration > 0:
            let minutes = Int(item.duration) / 60
            let seconds = Int(item.duration) % 60
            return "\(minutes):\(String(format: "%02d", seconds))"
        case "pdf" where item.pageCount > 0:
            return "\(item.pageCount) page\(item.pageCount == 1 ? "" : "s")"
        case _ where item.wordCount > 0:
            if item.wordCount >= 1_000 {
                let thousands = Double(item.wordCount) / 1_000
                let precision = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))
                return "\(thousands.formatted(precision))K words"
            }
            return "\(item.wordCount) words"
        default:
            return nil
        }
    }
}

struct LibraryDetailLoader: View {
    let reference: LibraryReference
    @State private var item: LibraryItem?
    @State private var errorMessage: String?
    @State private var isLoading = false

    private let service = MediaToolsService.shared

    var body: some View {
        Group {
            if let item {
                ItemDetailView(item: item)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Couldn’t Open Item", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.brand500)
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(Theme.brand500)
                    Text("Opening item…")
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
        .task(id: reference) { await load() }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            item = try await service.getLibraryItem(reference)
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Detail Navigation Model

enum LibraryItem: Hashable {
    case transcript(Transcript)
    case audio(AudioTranscription)
    case pdf(PDFExtraction)

    func hash(into hasher: inout Hasher) {
        switch self {
        case .transcript(let transcript):
            hasher.combine("transcript")
            hasher.combine(transcript.id)
        case .audio(let audio):
            hasher.combine("audio")
            hasher.combine(audio.id)
        case .pdf(let pdf):
            hasher.combine("pdf")
            hasher.combine(pdf.id)
        }
    }

    static func == (lhs: LibraryItem, rhs: LibraryItem) -> Bool {
        switch (lhs, rhs) {
        case (.transcript(let left), .transcript(let right)): left.id == right.id
        case (.audio(let left), .audio(let right)): left.id == right.id
        case (.pdf(let left), .pdf(let right)): left.id == right.id
        default: false
        }
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let status: String

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(backgroundColor.opacity(0.15))
            .foregroundStyle(backgroundColor)
            .clipShape(Capsule())
            .fixedSize(horizontal: true, vertical: false)
    }

    private var label: String {
        switch status {
        case "pending": "Queued"
        case "processing": "Processing"
        case "failed": "Needs attention"
        default: status.capitalized
        }
    }

    private var backgroundColor: Color {
        switch status {
        case "completed": Theme.success
        case "processing", "pending": Theme.warning
        case "failed": Theme.error
        default: Theme.textMuted
        }
    }
}

extension LibraryListItem {
    static var uiTestSamples: [LibraryListItem] {
        [
            LibraryListItem(
                id: "video-1", itemType: "youtube", title: "Weekly product review",
                subtitle: "Shimizu Technology", status: "completed", wordCount: 4260,
                duration: 0, pageCount: 0, summaryStatus: "completed", favorite: true,
                archived: false, tags: ["product"], createdAt: Date()
            ),
            LibraryListItem(
                id: "audio-1", itemType: "audio", title: "Team planning session.m4a",
                subtitle: "EN", status: "processing", wordCount: 0, duration: 128,
                pageCount: 0, summaryStatus: "", favorite: false, archived: false,
                tags: ["meeting"], createdAt: Date().addingTimeInterval(-60)
            ),
            LibraryListItem(
                id: "pdf-1", itemType: "pdf", title: "Client discovery notes.pdf",
                subtitle: "18 pages", status: "completed", wordCount: 6820, duration: 0,
                pageCount: 18, summaryStatus: "", favorite: false, archived: false,
                tags: ["client"], createdAt: Date().addingTimeInterval(-120)
            ),
            LibraryListItem(
                id: "audio-2", itemType: "audio", title: "Voice memo – launch follow-up",
                subtitle: "Recording", status: "failed", wordCount: 0, duration: 42,
                pageCount: 0, summaryStatus: "", favorite: false, archived: false,
                tags: [], createdAt: Date().addingTimeInterval(-180)
            ),
        ]
    }
}
