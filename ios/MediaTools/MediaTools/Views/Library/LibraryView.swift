import SwiftUI

struct LibraryView: View {
    @State private var model: LibraryViewModel
    @State private var operationError: String?
    @State private var isSelecting = false
    @State private var selectedReferences: Set<LibraryReference> = []
    @State private var pendingDeletion: [LibraryReference] = []
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var collectionTarget: LibraryReference?
    @State private var presentedReference: LibraryReference?

    private let service = MediaToolsService.shared
    private let previewItems: [LibraryListItem]?

    init(model: LibraryViewModel? = nil, previewItems: [LibraryListItem]? = nil) {
        self.previewItems = previewItems
        _model = State(
            initialValue: model ?? LibraryViewModel(previewItems: previewItems)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            mediaFilterBar
            libraryList
        }
        .background(Theme.surface)
        .navigationTitle("Library")
        .searchable(text: $model.searchText, prompt: "Search all media")
        .toolbar { libraryToolbar }
        .safeAreaInset(edge: .bottom) { selectionBar }
        .navigationDestination(item: $presentedReference) { reference in
            LibraryDetailLoader(
                reference: reference,
                previewTitle: previewItems?.first { $0.reference == reference }?.displayTitle
            )
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
        .task(id: model.query) {
            let requestedQuery = model.query
            if !requestedQuery.search.isEmpty {
                do {
                    try await Task.sleep(for: .milliseconds(300))
                } catch {
                    return
                }
            }
            await model.loadIfNeeded(for: requestedQuery)
        }
    }

    private var mediaFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryMediaFilter.allCases, id: \.self) { filter in
                    Button {
                        withAnimation(Theme.springSnappy) {
                            model.selectedType = filter
                            leaveSelectionMode()
                        }
                    } label: {
                        Text(filter.title)
                            .font(Theme.body(13, weight: .medium))
                            .foregroundStyle(model.selectedType == filter ? Color.white : Theme.textSecondary)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(model.selectedType == filter ? Theme.brand500 : Theme.surfaceElevated)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.selectedType == filter ? .isSelected : [])
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

            if model.isLoading && model.items.isEmpty {
                loadingRow
            } else if let loadError = model.loadError, model.items.isEmpty {
                errorRow(loadError)
            } else if model.items.isEmpty {
                emptyRow
            } else {
                if model.selectedStatus != .all || model.sortOrder != .newest || !model.query.search.isEmpty {
                    filterSummaryRow
                }

                ForEach(model.items, id: \.reference) { item in
                    libraryRow(item)
                        .id(item.reference)
                        .task(id: item.reference) {
                            await model.prefetchIfNeeded(after: item.reference)
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                if model.hasMore && (model.isLoadingMore || model.loadError != nil) {
                    loadMoreRow
                } else if model.totalItems > 0 && !model.hasMore {
                    Text("\(model.totalItems) item\(model.totalItems == 1 ? "" : "s")")
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
        .scrollPosition(id: $model.visibleReference)
        .refreshable {
            await model.refresh()
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
                    ForEach(LibraryStatusFilter.allCases, id: \.self) { filter in
                        Button {
                            model.selectedStatus = filter
                            leaveSelectionMode()
                        } label: {
                            if model.selectedStatus == filter {
                                Label(filter.title, systemImage: "checkmark")
                            } else {
                                Text(filter.title)
                            }
                        }
                    }
                }

                Section("Sort") {
                    ForEach(LibrarySortOrder.allCases, id: \.self) { order in
                        Button {
                            model.sortOrder = order
                            leaveSelectionMode()
                        } label: {
                            if model.sortOrder == order {
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
                    .disabled(model.items.isEmpty || isSelecting)

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
            .accessibilityLabel("\(selectedReferences.contains(item.reference) ? "Deselect" : "Select") \(item.displayTitle)")
        } else {
            Button {
                model.visibleReference = item.reference
                presentedReference = item.reference
            } label: {
                HStack(spacing: 10) {
                    LibrarySummaryRow(item: item, selectionState: nil)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textMuted)
                        .accessibilityHidden(true)
                }
                .cardStyle(padding: 12)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library-row-\(item.reference.id)")
            .accessibilityLabel("Open \(item.displayTitle)")
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
                Task { await model.retryInitialLoad() }
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
            Label(emptyTitle, systemImage: model.query.search.isEmpty ? "tray" : "magnifyingglass")
        } description: {
            Text(emptyDescription)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var emptyTitle: String {
        if !model.query.search.isEmpty { return "No Results" }
        if model.selectedStatus != .all { return "No Matching Items" }
        return "Your Library Is Ready"
    }

    private var emptyDescription: String {
        if !model.query.search.isEmpty {
            return "Try a different title, transcript phrase, summary, or tag."
        }
        if model.selectedStatus != .all {
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
            if model.selectedStatus != .all || model.sortOrder != .newest {
                Button("Reset") {
                    model.selectedStatus = .all
                    model.sortOrder = .newest
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
        if !model.query.search.isEmpty { parts.append("Results for “\(model.query.search)”") }
        if model.selectedStatus != .all { parts.append(model.selectedStatus.title) }
        if model.sortOrder != .newest { parts.append(model.sortOrder.title) }
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
            if model.isLoadingMore {
                ProgressView()
                    .tint(Theme.brand500)
                    .accessibilityLabel("Loading more library items")
            } else if model.loadError != nil {
                Button("Load More") {
                    Task { await model.retryNextPage() }
                }
                .frame(minWidth: 120, minHeight: 44)
            }
            Spacer()
        }
        .frame(minHeight: 44)
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
            model.remove(deleted)
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

        model.remove(deleted)
        SpotlightService.removeLibraryItems(Array(deleted))
        selectedReferences = Set(failed)
        if failed.isEmpty {
            leaveSelectionMode()
            Haptics.success()
            await model.refresh()
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
                Text(item.displayTitle)
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)

                if let displaySubtitle = item.displaySubtitle {
                    Text(displaySubtitle)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    StatusBadge(status: item.status)
                    if let metadataText {
                        Text(metadataText)
                            .font(Theme.caption())
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
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

    private var metadataText: String? {
        [detailText, item.createdDateText]
            .compactMap { $0 }
            .joined(separator: " · ")
            .nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct LibraryDetailLoader: View {
    let reference: LibraryReference
    var previewTitle: String? = nil
    @State private var item: LibraryItem?
    @State private var errorMessage: String?
    @State private var isLoading = false

    private let service = MediaToolsService.shared

    var body: some View {
        Group {
            if let previewTitle {
                ContentUnavailableView {
                    Label(previewTitle, systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("Library navigation preview")
                }
                .navigationTitle(previewTitle)
                .navigationBarTitleDisplayMode(.inline)
            } else if let item {
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
        .task(id: reference) {
            guard previewTitle == nil else { return }
            await load()
        }
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

#if DEBUG
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

    static var uiTestPaginationSamples: [LibraryListItem] {
        var samples: [LibraryListItem] = []
        for index in 1...60 {
            let createdAt = Date().addingTimeInterval(TimeInterval(-index * 60))
            let item = LibraryListItem(
                id: "audio-\(index)",
                itemType: "audio",
                title: String(format: "Recording %02d.m4a", index),
                subtitle: "EN",
                status: "completed",
                wordCount: 120 + index,
                duration: Double(30 + index),
                pageCount: 0,
                summaryStatus: "",
                favorite: false,
                archived: false,
                tags: [],
                createdAt: createdAt
            )
            samples.append(item)
        }
        return samples
    }
}
#endif
