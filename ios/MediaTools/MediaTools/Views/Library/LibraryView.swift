import SwiftUI

struct LibraryView: View {
    @State private var model: LibraryViewModel
    let isActive: Bool
    @State private var operationError: String?
    @State private var isSelecting = false
    @State private var selectedReferences: Set<LibraryReference> = []
    @State private var pendingDeletion: [LibraryReference] = []
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var collectionTarget: LibraryReference?
    @State private var optionsTarget: DeviceItemTarget?
    @State private var isVisible = false
    @State private var listWidth: CGFloat = 0
    @FocusState private var isSearchFocused: Bool
    @Environment(AppNavigator.self) private var navigator
    @Environment(RecordingCoordinator.self) private var recorder
    @Environment(RecordingUploadCoordinator.self) private var uploader
    @Environment(\.scenePhase) private var scenePhase

    private let service = MediaToolsService.shared
    private let previewItems: [LibraryListItem]?

    /// Items running on the server have no local event to report completion, so
    /// the visible Library checks on them at this pace and stops once they settle.
    private static let activeItemRefreshInterval: Duration = .seconds(15)

    init(
        model: LibraryViewModel,
        previewItems: [LibraryListItem]? = nil,
        isActive: Bool = true
    ) {
        self.previewItems = previewItems
        self.isActive = isActive
        _model = State(initialValue: model)
    }

    var body: some View {
        libraryList
            .themedListBackground()
            .readableContentWidth()
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { listWidth = $0 }
            .navigationTitle("Library")
            .toolbar(.hidden, for: .navigationBar)
            .statusBarBackdrop()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isSelecting { selectionBar }
            }
            .deviceItemActions(target: $optionsTarget)
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
            .task(id: model.selectedCollection) {
                await model.loadSelectedCollection()
            }
            .onAppear {
                isVisible = true
                Task { await model.refreshIfStale() }
                // The filter menu lists these. Every screen that changes them reloads
                // them, so one load here is enough.
                guard previewItems == nil, service.collections.isEmpty else { return }
                Task { await service.loadCollections() }
            }
            .onDisappear { isVisible = false }
            .onChange(of: isActive) { _, active in
                // Tabs stay alive underneath, so coming back here is not an onAppear.
                if active {
                    Task { await model.refreshIfStale() }
                } else {
                    leaveSelectionMode()
                }
            }
            .onChange(of: isSelecting) { _, selecting in
                navigator.isTabBarSuppressed = selecting
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, isActive else { return }
                Task { await model.refreshIfStale() }
            }
            .onChange(of: recorder.uploadStateSignature) { _, _ in
                Task { await model.refresh() }
            }
            .onChange(of: uploader.sharedDocumentImports) { _, _ in
                Task { await model.refresh() }
            }
            .task(id: isVisible && isActive && scenePhase == .active && model.hasActiveItems) {
                guard isVisible, isActive, scenePhase == .active, model.hasActiveItems else { return }
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: Self.activeItemRefreshInterval)
                    } catch {
                        return
                    }
                    await model.refresh()
                }
            }
    }

    // MARK: - Device uploads

    /// Audio still on this iPhone has no server row yet. Showing it here means
    /// a new recording is visible in the Library from the moment it is saved.
    private var deviceRecordings: [LocalRecording] {
        guard model.selectedCollection == nil,
              model.selectedType == .all || model.selectedType == .audio,
              model.selectedStatus == .all || model.selectedStatus == .active,
              model.query.search.isEmpty,
              !model.showsArchived,
              !model.showsFavoritesOnly
        else { return [] }
        let serverIDs = Set(model.items.map(\.reference))
        return recorder.availableRecordings.filter { recording in
            guard let remoteID = recording.remoteTranscriptionID else { return true }
            return !serverIDs.contains(LibraryReference(itemType: "audio", itemId: remoteID))
        }
    }

    /// Shares that failed, or that wait for a tap, stay visible until dealt with.
    private var sharesNeedingAttention: [ShareInboxStore.Item] {
        uploader.sharesNeedingAttention.filter { model.showsShare(ofKind: $0.resolvedKind) }
    }

    private var hasDeviceRows: Bool {
        !deviceRecordings.isEmpty || !sharesNeedingAttention.isEmpty
    }

    @ViewBuilder
    private var deviceRows: some View {
        if hasDeviceRows {
            Section {
                sectionLabelRow("On this \(UIDevice.current.localizedModel)")
                ForEach(deviceRecordings) { recording in
                    DeviceRecordingRow(
                        recording: recording,
                        onTap: {
                            if let remoteID = recording.remoteTranscriptionID {
                                open(LibraryReference(itemType: "audio", itemId: remoteID))
                            } else {
                                optionsTarget = .recording(recording.id)
                            }
                        },
                        onTranscribe: {
                            Task { await uploader.transcribe(recording) }
                        },
                        onOptions: { optionsTarget = .recording(recording.id) }
                    )
                    .libraryRowStyle(insets: rowInsets)
                }
                ForEach(sharesNeedingAttention) { item in
                    DeviceShareRow(
                        item: item,
                        onTap: { optionsTarget = .share(item.id) },
                        onAction: { Task { await uploader.retrySharedItem(item) } }
                    )
                    .libraryRowStyle(insets: rowInsets)
                }
            }
        }
    }

    // MARK: - List

    private var libraryList: some View {
        List {
            headerRow
            searchRow
            chipRow

            if let operationError {
                dismissibleErrorRow(operationError)
            }

            if showsFilterSummary {
                filterSummaryRow
            }

            deviceRows

            if model.selectedCollection != nil {
                collectionRows
            } else if model.isLoading && model.items.isEmpty {
                loadingRow
            } else if let loadError = model.loadError, model.items.isEmpty {
                errorRow(loadError)
            } else if model.items.isEmpty {
                if !hasDeviceRows {
                    emptyRow
                }
            } else {
                Section {
                    if hasDeviceRows { sectionLabelRow("In your library") }
                    ForEach(model.items, id: \.reference) { item in
                        libraryRow(item)
                            .id(item.reference)
                            .task(id: item.reference) {
                                await model.prefetchIfNeeded(after: item.reference)
                            }
                            .libraryRowStyle(insets: rowInsets)
                    }
                }

                if model.hasMore && (model.isLoadingMore || model.loadError != nil) {
                    loadMoreRow
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(0)
        .environment(\.defaultMinListHeaderHeight, 0)
        .scrollPosition(id: $model.visibleReference)
        .scrollDismissesKeyboard(.immediately)
        .contentMargins(.bottom, 24, for: .scrollContent)
        .refreshable {
            await model.refresh()
            if model.selectedCollection != nil {
                await model.loadSelectedCollection()
            }
        }
    }

    /// Lines rows up with the title and search field above them.
    private var rowInsets: EdgeInsets {
        let margin = Theme.pageMargin(forWidth: min(listWidth, Theme.readableWidth))
        return EdgeInsets(top: 0, leading: margin, bottom: 0, trailing: margin)
    }

    /// A row rather than a section header, which would stick while scrolling and
    /// ignore the width limit on iPad.
    private func sectionLabelRow(_ title: String) -> some View {
        chromeRow {
            SectionLabel(title)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chromeRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .listRowInsets(EdgeInsets(top: 0, leading: rowInsets.leading, bottom: 0, trailing: rowInsets.trailing))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    // MARK: - Title, search, chips

    private var headerRow: some View {
        chromeRow {
            ScreenHeader("Library") {
                if isSelecting {
                    Button("Done") { leaveSelectionMode() }
                        .buttonStyle(QuietButtonStyle())
                        .accessibilityIdentifier("library.done")
                } else {
                    filterMenu
                    addMenu
                }
            }
            .padding(.trailing, -8)
        }
    }

    private var searchRow: some View {
        chromeRow {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline)
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
                TextField(
                    "Search",
                    text: $model.searchText,
                    prompt: Text("Search transcripts and summaries").foregroundStyle(Theme.textSecondary)
                )
                .font(.body)
                .foregroundStyle(Theme.text)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .focused($isSearchFocused)
                .accessibilityLabel("Search transcripts and summaries")
                .accessibilityIdentifier("library.search")
                if !model.searchText.isEmpty {
                    Button {
                        model.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.leading, 12)
            .frame(minHeight: 44)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.radiusMedium, style: .continuous))
            .padding(.top, 4)
        }
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(LibraryChip.allCases) { chip in
                    chipButton(chip)
                }
            }
            .padding(.horizontal, rowInsets.leading)
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func chipButton(_ chip: LibraryChip) -> some View {
        let isSelected = model.selectedCollection == nil && model.selectedChip == chip
        return Button {
            withMotion(Theme.quick) {
                model.selectedChip = chip
                leaveSelectionMode()
            }
        } label: {
            HStack(spacing: 5) {
                Text(chip.title)
                if isSelected, model.totalItems > 0 {
                    Text(verbatim: "\(model.totalItems)")
                        .monospacedDigit()
                }
            }
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(isSelected ? Theme.onAccent : Theme.textSecondary)
            .padding(.horizontal, 13)
            .frame(minHeight: 34)
            .background(isSelected ? Theme.accentFill : Theme.surface2, in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("library.chip.\(chip.rawValue)")
    }

    /// The rarer ways to narrow the list, and the way into selecting.
    private var filterMenu: some View {
        Menu {
            Section("Status") {
                ForEach(LibraryStatusFilter.allCases, id: \.self) { filter in
                    Button {
                        model.selectedStatus = filter
                        leaveSelectionMode()
                    } label: {
                        checkedLabel(filter.title, isSelected: model.selectedStatus == filter)
                    }
                }
            }

            Section("Sort") {
                ForEach(LibrarySortOrder.allCases, id: \.self) { order in
                    Button {
                        model.sortOrder = order
                        leaveSelectionMode()
                    } label: {
                        checkedLabel(order.title, isSelected: model.sortOrder == order)
                    }
                }
            }

            Section {
                Menu {
                    Button {
                        model.selectedCollection = nil
                        leaveSelectionMode()
                    } label: {
                        checkedLabel("All collections", isSelected: model.selectedCollection == nil)
                    }
                    ForEach(service.collections) { collection in
                        Button {
                            model.selectedCollection = LibraryCollectionFilter(
                                id: collection.id,
                                name: collection.name
                            )
                            leaveSelectionMode()
                        } label: {
                            checkedLabel(collection.name, isSelected: model.selectedCollection?.id == collection.id)
                        }
                    }
                } label: {
                    Label("Collection", systemImage: "folder")
                }
                .accessibilityIdentifier("library.collections")
            }

            Section {
                Button {
                    isSelecting = true
                } label: {
                    Label("Select Items", systemImage: "checkmark.circle")
                }
                .disabled(model.items.isEmpty || model.selectedCollection != nil || isSelecting)
            }
        } label: {
            HeaderIconLabel(systemImage: "line.3.horizontal.decrease")
        }
        .accessibilityLabel("Library actions")
        .accessibilityIdentifier("library.filter")
    }

    private var addMenu: some View {
        Menu {
            Button {
                navigator.isImporterPresented = true
            } label: {
                Label("Import Audio", systemImage: "waveform")
            }
            Button {
                navigator.push(.addLink)
            } label: {
                Label("Add a Link", systemImage: "link")
            }
            Button {
                navigator.push(.addPDF)
            } label: {
                Label("Upload a PDF", systemImage: "doc")
            }
        } label: {
            HeaderIconLabel(systemImage: "plus")
        }
        .accessibilityLabel("Add")
        .accessibilityIdentifier("library.add")
    }

    @ViewBuilder
    private func checkedLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    // MARK: - Rows

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
            }
            .buttonStyle(RowButtonStyle())
            .accessibilityLabel("\(selectedReferences.contains(item.reference) ? "Deselect" : "Select") \(item.displayTitle)")
        } else {
            Button {
                model.visibleReference = item.reference
                open(item.reference)
            } label: {
                LibrarySummaryRow(item: item, selectionState: nil)
            }
            .buttonStyle(RowButtonStyle())
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
                .tint(Theme.heroIcon)
            }
        }
    }

    private func open(_ reference: LibraryReference) {
        navigator.push(.item(reference))
    }

    @ViewBuilder
    private var collectionRows: some View {
        if model.isLoadingCollection && model.collectionItems.isEmpty {
            loadingRow
        } else if let error = model.collectionError {
            chromeRow {
                QuietPlaceholder(
                    systemImage: "folder",
                    title: "Couldn’t Open Collection",
                    message: error
                ) {
                    Button("Try Again") {
                        Task { await model.loadSelectedCollection() }
                    }
                    .buttonStyle(QuietButtonStyle())
                }
            }
        } else if visibleCollectionItems.isEmpty {
            chromeRow {
                QuietPlaceholder(
                    systemImage: model.query.search.isEmpty ? "tray" : "magnifyingglass",
                    title: model.query.search.isEmpty ? "Empty Collection" : "No Results",
                    message: model.query.search.isEmpty
                        ? "Swipe right on anything in your Library to add it."
                        : "Try a different title."
                )
            }
        } else {
            ForEach(visibleCollectionItems) { item in
                Button {
                    open(LibraryReference(itemType: item.itemType, itemId: item.itemId))
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.itemTitle ?? item.itemId)
                            .font(.rowTitle)
                            .foregroundStyle(Theme.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let status = item.itemStatus, let attention = ItemAttention(status: status) {
                            AttentionLabel(attention: attention)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.vertical, 10)
                }
                .buttonStyle(RowButtonStyle())
                .libraryRowStyle(insets: rowInsets)
            }
        }
    }

    /// Search here covers titles; the server's full-text search has no collection scope.
    private var visibleCollectionItems: [CollectionItem] {
        let search = model.query.search
        guard !search.isEmpty else { return model.collectionItems }
        return model.collectionItems.filter {
            ($0.itemTitle ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    private var loadingRow: some View {
        chromeRow {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading your library…")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 240)
            .accessibilityElement(children: .combine)
        }
    }

    private func errorRow(_ message: String) -> some View {
        chromeRow {
            QuietPlaceholder(
                systemImage: "wifi.exclamationmark",
                title: "Couldn’t Load Library",
                message: message
            ) {
                Button("Try Again") {
                    Task { await model.retryInitialLoad() }
                }
                .buttonStyle(QuietButtonStyle())
            }
        }
    }

    private var emptyRow: some View {
        chromeRow {
            QuietPlaceholder(
                systemImage: model.query.search.isEmpty ? "tray" : "magnifyingglass",
                title: emptyTitle,
                message: emptyDescription
            )
        }
    }

    private var emptyTitle: String {
        if !model.query.search.isEmpty { return "No Results" }
        if model.showsArchived { return "No Archived Items" }
        if model.showsFavoritesOnly { return "No Starred Items" }
        if model.selectedStatus != .all || model.selectedType != .all { return "No Matching Items" }
        return "Your Library Is Ready"
    }

    private var emptyDescription: String {
        if !model.query.search.isEmpty {
            return "Try a different title, transcript phrase, summary, or tag."
        }
        if model.showsArchived {
            return "Items you archive stay here until you unarchive them."
        }
        if model.showsFavoritesOnly {
            return "Star a recording from its menu to find it here."
        }
        if model.selectedStatus != .all || model.selectedType != .all {
            return "Change the filter to see more of your library."
        }
        return "Tap Record below, or use the Add button for a link or a PDF."
    }

    private var showsFilterSummary: Bool {
        model.selectedStatus != .all
            || model.sortOrder != .newest
            || !model.query.search.isEmpty
            || model.selectedCollection != nil
    }

    private var filterSummaryRow: some View {
        chromeRow {
            HStack(spacing: 8) {
                Text(filterSummary)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if model.selectedStatus != .all || model.sortOrder != .newest || model.selectedCollection != nil {
                    Button("Reset") {
                        model.selectedStatus = .all
                        model.sortOrder = .newest
                        model.selectedCollection = nil
                    }
                    .buttonStyle(QuietButtonStyle())
                }
            }
        }
    }

    private var filterSummary: String {
        var parts: [String] = []
        if !model.query.search.isEmpty { parts.append("Results for “\(model.query.search)”") }
        if let collection = model.selectedCollection { parts.append(collection.name) }
        if model.selectedStatus != .all { parts.append(model.selectedStatus.title) }
        if model.sortOrder != .newest { parts.append(model.sortOrder.title) }
        return parts.joined(separator: " · ")
    }

    private func dismissibleErrorRow(_ message: String) -> some View {
        chromeRow {
            HStack(alignment: .top, spacing: 10) {
                InlineError(message)
                Button {
                    operationError = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss error")
            }
        }
    }

    private var loadMoreRow: some View {
        chromeRow {
            HStack {
                Spacer()
                if model.isLoadingMore {
                    ProgressView()
                        .accessibilityLabel("Loading more library items")
                } else if model.loadError != nil {
                    Button("Load More") {
                        Task { await model.retryNextPage() }
                    }
                    .buttonStyle(QuietButtonStyle())
                }
                Spacer()
            }
            .frame(minHeight: 44)
        }
    }

    // MARK: - Selecting

    /// Takes the tab bar's place while selecting.
    private var selectionBar: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 12) {
                Text("\(selectedReferences.count) selected")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button(role: .destructive) {
                    requestDeletion(Array(selectedReferences))
                } label: {
                    if isDeleting {
                        ProgressView()
                    } else {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .buttonStyle(QuietButtonStyle(color: Theme.danger))
                .disabled(selectedReferences.isEmpty || isDeleting)
            }
            .pageMargin()
            .padding(.vertical, 6)
        }
        .barBackground()
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
        } else {
            isSelecting = true
            operationError = "\(failed.count) item\(failed.count == 1 ? "" : "s") couldn’t be deleted. The failed selection was kept so you can try again."
            Haptics.error()
        }
    }
}

private extension View {
    /// Plain rows on the page with a hairline between them, not cards.
    func libraryRowStyle(insets: EdgeInsets) -> some View {
        self
            .listRowInsets(insets)
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(Theme.separator)
    }
}

/// A status worth interrupting a calm list for. A finished item shows nothing.
struct ItemAttention: Equatable {
    let text: String
    let isWorking: Bool

    init?(status: String) {
        switch status {
        case "pending":
            text = "Queued"
            isWorking = true
        case "processing":
            text = "Transcribing"
            isWorking = true
        case "failed":
            text = "Needs attention"
            isWorking = false
        default:
            return nil
        }
    }
}

struct AttentionLabel: View {
    let attention: ItemAttention

    var body: some View {
        HStack(spacing: 5) {
            if attention.isWorking {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Theme.textSecondary)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(Theme.warning)
                    .accessibilityHidden(true)
            }
            Text(attention.text)
        }
        .font(.footnote)
        .foregroundStyle(attention.isWorking ? Theme.textSecondary : Theme.text)
    }
}

/// Mirrors `LibrarySummaryRow` for a recording the server does not list yet, with
/// what it needs right on the row.
private struct DeviceRecordingRow: View {
    let recording: LocalRecording
    let onTap: () -> Void
    let onTranscribe: () -> Void
    let onOptions: () -> Void
    @Environment(RecordingCoordinator.self) private var recorder
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: 10))
        layout {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        TypeTile(itemType: "audio")
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recording.needsYouTitle)
                            .font(.rowTitle)
                            .foregroundStyle(Theme.text)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                            .multilineTextAlignment(.leading)
                        if recording.isUploadInProgress {
                            DeviceProgressLabel(recording: recording)
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Image(systemName: "exclamationmark.circle")
                                    .foregroundStyle(Theme.warning)
                                    .accessibilityHidden(true)
                                Text(recording.needsYouDetail)
                                    .foregroundStyle(Theme.textSecondary)
                                    .multilineTextAlignment(.leading)
                            }
                            .font(.footnote)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
            .accessibilityIdentifier("library-device-\(recording.id.uuidString)")

            if !recording.isUploadInProgress {
                if recording.canUpload {
                    NeedsYouPill(title: "Transcribe", isPrimary: true, action: onTranscribe)
                        .disabled(recorder.isRecording || recorder.isStarting)
                        .accessibilityIdentifier("recording.transcribe.\(recording.id.uuidString)")
                } else {
                    NeedsYouPill(title: "Options", isPrimary: false, action: onOptions)
                        .accessibilityIdentifier("recording.options.\(recording.id.uuidString)")
                }
            }
        }
    }
}

/// A share that failed or that waits for a tap, with that tap on the row.
private struct DeviceShareRow: View {
    let item: ShareInboxStore.Item
    let onTap: () -> Void
    let onAction: () -> Void
    @Environment(RecordingUploadCoordinator.self) private var uploader
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: 10))
        layout {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        TypeTile(itemType: item.resolvedKind == .link ? "youtube" : "audio")
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.originalName)
                            .font(.rowTitle)
                            .foregroundStyle(Theme.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Label {
                            Text(uploader.shareStatusMessage(for: item))
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                        } icon: {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundStyle(Theme.warning)
                        }
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
            .accessibilityIdentifier("library-share-\(item.id)")

            NeedsYouPill(title: uploader.shareActionTitle(for: item), isPrimary: true, action: onAction)
        }
    }
}

/// A Studio row: real peaks or a type icon, the title with its length, what it says,
/// and where it lives. Anything missing collapses without leaving a gap.
struct LibrarySummaryRow: View {
    let item: LibraryListItem
    let selectionState: Bool?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let selectionState {
                Image(systemName: selectionState ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selectionState ? Theme.accentText : Theme.textSecondary)
                    .frame(minHeight: 44)
            }

            if !dynamicTypeSize.isAccessibilitySize {
                RowLeadingVisual(item: item)
            }

            VStack(alignment: .leading, spacing: 2) {
                // At accessibility sizes the length drops into the meta line, so the
                // title runs in full rather than one word a line.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.displayTitle)
                        .font(.rowTitle)
                        .foregroundStyle(Theme.text)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !dynamicTypeSize.isAccessibilitySize, let detail = item.trailingDetail {
                        Text(detail)
                            .font(.number)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize()
                    }
                }

                if let excerpt = item.displayExcerpt {
                    Text(excerpt)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                        .multilineTextAlignment(.leading)
                }

                RowMetaLine(item: item, showsDate: true)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.vertical, 12)
    }
}

/// "Baby · Oct 19", with the collection's dot. An unfinished item says that instead.
struct RowMetaLine: View {
    let item: LibraryListItem
    let showsDate: Bool
    /// Home's cards have no column for the length, so it joins this line.
    var showsLength = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var parts: [String] {
        var parts: [String] = []
        if let collection = item.primaryCollection?.name { parts.append(collection) }
        if let source = item.sourceLabel { parts.append(source) }
        if showsLength || dynamicTypeSize.isAccessibilitySize, let detail = item.trailingDetail { parts.append(detail) }
        if let words = item.wordCountLabel { parts.append(words) }
        if showsDate, let date = MediaFormat.rowDate(item.createdAt) { parts.append(date) }
        return parts
    }

    var body: some View {
        HStack(spacing: 5) {
            if let attention = ItemAttention(status: item.status) {
                AttentionLabel(attention: attention)
            } else if let collection = item.primaryCollection {
                CollectionDot(colorKey: collection.color)
            }
            if item.favorite {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityLabel("Favorite")
            }
            // An unfinished row's title line has no room for its length at these sizes.
            if ItemAttention(status: item.status) != nil,
               showsLength || dynamicTypeSize.isAccessibilitySize,
               let detail = item.trailingDetail {
                Text(detail)
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }
            if !parts.isEmpty, ItemAttention(status: item.status) == nil {
                Text(parts.joined(separator: " · "))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .multilineTextAlignment(.leading)
            }
        }
    }
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
                        .buttonStyle(QuietButtonStyle())
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Opening item…")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
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
            // Opened from a notification, nothing has listed this item yet, and its
            // collections come only from the list. A new item is on the newest page, and
            // waiting briefly for that means the header never has to shift afterward.
            let rowLookup: Task<Void, Never>? = service.libraryRow(for: reference) == nil
                ? Task { _ = try? await service.listLibraryItems() }
                : nil
            let loaded = try await service.getLibraryItem(reference)
            if let rowLookup {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await rowLookup.value }
                    group.addTask { try? await Task.sleep(for: .seconds(1)) }
                    await group.next()
                    group.cancelAll()
                }
            }
            item = loaded
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
