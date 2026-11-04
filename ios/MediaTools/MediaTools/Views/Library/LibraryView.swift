import SwiftUI

struct LibraryView: View {
    @State private var model: LibraryViewModel
    @Binding private var path: [AppRoute]
    @State private var operationError: String?
    @State private var isSelecting = false
    @State private var selectedReferences: Set<LibraryReference> = []
    @State private var pendingDeletion: [LibraryReference] = []
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var collectionTarget: LibraryReference?
    @State private var isVisible = false
    @State private var isSearchPresented = false
    @State private var listWidth: CGFloat = 0
    @Environment(RecordingCoordinator.self) private var recorder
    @Environment(RecordingUploadCoordinator.self) private var uploader
    @Environment(\.scenePhase) private var scenePhase

    private let service = MediaToolsService.shared
    private let previewItems: [LibraryListItem]?

    /// Items running on the server have no local event to report completion, so
    /// the visible Library checks on them at this pace and stops once they settle.
    private static let activeItemRefreshInterval: Duration = .seconds(15)

    /// The in-app default, matching the recorder's own.
    private static let defaultContentType = "general"

    init(
        model: LibraryViewModel,
        previewItems: [LibraryListItem]? = nil,
        path: Binding<[AppRoute]>
    ) {
        self.previewItems = previewItems
        _model = State(initialValue: model)
        _path = path
    }

    var body: some View {
        libraryList
            .ledgerListBackground()
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { listWidth = $0 }
            .navigationTitle("Library")
            .searchable(
                text: $model.searchText,
                isPresented: $isSearchPresented,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search"
            )
            .toolbar { libraryToolbar }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
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
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await model.refreshIfStale() }
            }
            .onChange(of: recorder.uploadStateSignature) { _, _ in
                Task { await model.refresh() }
            }
            .onChange(of: uploader.sharedDocumentImports) { _, _ in
                Task { await model.refresh() }
            }
            .task(id: isVisible && scenePhase == .active && model.hasActiveItems) {
                guard isVisible, scenePhase == .active, model.hasActiveItems else { return }
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
              !model.showsArchived
        else { return [] }
        let serverIDs = Set(model.items.map(\.reference))
        return recorder.availableRecordings.filter { recording in
            guard let remoteID = recording.remoteTranscriptionID else { return true }
            return !serverIDs.contains(LibraryReference(itemType: "audio", itemId: remoteID))
        }
    }

    /// Shares that failed, or that wait for a tap, stay visible until dealt with.
    private var sharesNeedingAttention: [ShareInboxStore.Item] {
        model.selectedCollection == nil ? uploader.sharesNeedingAttention : []
    }

    private var hasDeviceRows: Bool {
        !deviceRecordings.isEmpty || !sharesNeedingAttention.isEmpty
    }

    @ViewBuilder
    private var deviceRows: some View {
        if hasDeviceRows {
            Section {
                ForEach(deviceRecordings) { recording in
                    Button {
                        if let remoteID = recording.remoteTranscriptionID {
                            open(LibraryReference(itemType: "audio", itemId: remoteID))
                        } else {
                            path.append(.record)
                        }
                    } label: {
                        DeviceRecordingRow(recording: recording)
                    }
                    .buttonStyle(RowButtonStyle())
                    .accessibilityIdentifier("library-device-\(recording.id.uuidString)")
                    .libraryRowStyle(insets: rowInsets)
                }
                ForEach(sharesNeedingAttention) { item in
                    Button {
                        path.append(.record)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.originalName)
                                .font(.ledgerRowTitle)
                                .foregroundStyle(Theme.text)
                                .lineLimit(2)
                            Label {
                                Text(uploader.shareStatusMessage(for: item))
                                    .lineLimit(3)
                            } icon: {
                                Image(systemName: "exclamationmark.circle")
                            }
                            .font(.footnote)
                            .foregroundStyle(Theme.text)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(RowButtonStyle())
                    .accessibilityIdentifier("library-share-\(item.id)")
                    .libraryRowStyle(insets: rowInsets)
                }
            } header: {
                dayHeader("On this iPhone")
            }
        }
    }

    // MARK: - List

    private var libraryList: some View {
        List {
            filterRow

            if let operationError {
                dismissibleErrorRow(operationError)
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
                if model.selectedStatus != .all
                    || model.sortOrder != .newest
                    || !model.query.search.isEmpty
                    || model.showsArchived {
                    filterSummaryRow
                }

                ForEach(LibraryDaySection.group(model.items)) { section in
                    Section {
                        ForEach(section.items, id: \.reference) { item in
                            libraryRow(item)
                                .id(item.reference)
                                .task(id: item.reference) {
                                    await model.prefetchIfNeeded(after: item.reference)
                                }
                                .libraryRowStyle(insets: rowInsets)
                        }
                    } header: {
                        dayHeader(section.title)
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
        .refreshable {
            await model.refresh()
            if model.selectedCollection != nil {
                await model.loadSelectedCollection()
            }
        }
    }

    /// Lines rows up with the large title and search field above them.
    private var rowInsets: EdgeInsets {
        let margin = Theme.pageMargin(forWidth: listWidth)
        return EdgeInsets(top: 0, leading: margin, bottom: 0, trailing: margin)
    }

    private func dayHeader(_ title: String) -> some View {
        Text(title)
            .font(.ledgerSectionLabel)
            .foregroundStyle(Theme.textSecondary)
            .textCase(nil)
            .padding(.top, 12)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(rowInsets)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Filter row

    private var filterRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                collectionMenu
                Spacer(minLength: 8)
                countLabel
                filterMenu
            }
            // Large text gets the whole line for the collection's name.
            VStack(alignment: .leading, spacing: 0) {
                collectionMenu
                HStack(spacing: 12) {
                    countLabel
                    Spacer(minLength: 8)
                    filterMenu
                }
            }
        }
        .frame(minHeight: 44)
        .listRowInsets(EdgeInsets(top: 0, leading: rowInsets.leading, bottom: 0, trailing: rowInsets.trailing - 8))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var countLabel: some View {
        if let countText {
            Text(countText)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var collectionMenu: some View {
        Menu {
            Button {
                model.selectedCollection = nil
                leaveSelectionMode()
            } label: {
                checkedLabel("All collections", isSelected: model.selectedCollection == nil)
            }
            Section {
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
            }
            Section {
                Button {
                    path.append(.collections)
                } label: {
                    Label("Manage Collections", systemImage: "folder")
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(model.selectedCollection?.name ?? "All collections")
                    .fixedSize()
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.accent)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Filter by collection")
        .accessibilityValue(model.selectedCollection?.name ?? "All collections")
        .accessibilityIdentifier("library.collections")
    }

    private var filterMenu: some View {
        Menu {
            if let filter = model.selectedCollection {
                Section {
                    Button {
                        path.append(.collection(filter.id))
                    } label: {
                        Label("Open Collection", systemImage: "folder")
                    }
                }
            } else {
                Section("Show") {
                    ForEach(LibraryMediaFilter.allCases, id: \.self) { filter in
                        Button {
                            withMotion(Theme.quick) {
                                model.selectedType = filter
                                leaveSelectionMode()
                            }
                        } label: {
                            checkedLabel(filter.title, isSelected: model.selectedType == filter)
                        }
                    }
                }

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
                    Button {
                        model.showsArchived.toggle()
                        leaveSelectionMode()
                    } label: {
                        Label(
                            model.showsArchived ? "Hide Archived" : "Show Archived",
                            systemImage: model.showsArchived ? "tray.full" : "archivebox"
                        )
                    }
                }

                Section {
                    Button {
                        isSelecting = true
                    } label: {
                        Label("Select Items", systemImage: "checkmark.circle")
                    }
                    .disabled(model.items.isEmpty || isSelecting)
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.body)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Library actions")
    }

    @ViewBuilder
    private func checkedLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var countText: String? {
        if model.selectedCollection != nil {
            let count = model.collectionItems.count
            return count > 0 ? "\(count) item\(count == 1 ? "" : "s")" : nil
        }
        guard model.totalItems > 0 else { return nil }
        let noun = model.selectedType == .audio ? "recording" : "item"
        return "\(model.totalItems) \(noun)\(model.totalItems == 1 ? "" : "s")"
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { leaveSelectionMode() }
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    path.append(.addLink)
                } label: {
                    Label("Add a Link", systemImage: "link")
                }
                Button {
                    path.append(.addPDF)
                } label: {
                    Label("Upload a PDF", systemImage: "doc")
                }
                Button {
                    path.append(.importAudio)
                } label: {
                    Label("Import Audio", systemImage: "waveform")
                }
            } label: {
                Image(systemName: "plus")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Add")
            .accessibilityIdentifier("library.add")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                path.append(.settings)
            } label: {
                Image(systemName: "gearshape")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("library.settings")
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
                .tint(Theme.accentFill)
            }
        }
    }

    private func open(_ reference: LibraryReference) {
        path.append(.item(reference))
    }

    @ViewBuilder
    private var collectionRows: some View {
        if model.isLoadingCollection && model.collectionItems.isEmpty {
            loadingRow
        } else if let error = model.collectionError {
            ContentUnavailableView {
                Label("Couldn’t Open Collection", systemImage: "folder")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") {
                    Task { await model.loadSelectedCollection() }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, minHeight: 300)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else if visibleCollectionItems.isEmpty {
            ContentUnavailableView(
                model.query.search.isEmpty ? "Empty Collection" : "No Results",
                systemImage: model.query.search.isEmpty ? "tray" : "magnifyingglass",
                description: Text(
                    model.query.search.isEmpty
                        ? "Swipe right on anything in your Library to add it."
                        : "Try a different title."
                )
            )
            .frame(maxWidth: .infinity, minHeight: 300)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else {
            ForEach(visibleCollectionItems) { item in
                Button {
                    open(LibraryReference(itemType: item.itemType, itemId: item.itemId))
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.itemTitle ?? item.itemId)
                            .font(.ledgerRowTitle)
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
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading your library…")
                .font(.subheadline)
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
        if model.showsArchived { return "No Archived Items" }
        if model.selectedStatus != .all { return "No Matching Items" }
        return "Your Library Is Ready"
    }

    private var emptyDescription: String {
        if !model.query.search.isEmpty {
            return "Try a different title, transcript phrase, summary, or tag."
        }
        if model.showsArchived {
            return "Items you archive stay here until you unarchive them."
        }
        if model.selectedStatus != .all {
            return "Change the status filter to see more of your library."
        }
        return "Tap Record below, or use the Add button for a link or a PDF."
    }

    private var filterSummaryRow: some View {
        HStack(spacing: 8) {
            Text(filterSummary)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            if model.selectedStatus != .all || model.sortOrder != .newest || model.showsArchived {
                Button("Reset") {
                    model.selectedStatus = .all
                    model.sortOrder = .newest
                    model.showsArchived = false
                }
                .buttonStyle(QuietButtonStyle())
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var filterSummary: String {
        var parts: [String] = []
        if !model.query.search.isEmpty { parts.append("Results for “\(model.query.search)”") }
        if model.showsArchived { parts.append("Archived") }
        if model.selectedStatus != .all { parts.append(model.selectedStatus.title) }
        if model.sortOrder != .newest { parts.append(model.sortOrder.title) }
        return parts.joined(separator: " · ")
    }

    private func dismissibleErrorRow(_ message: String) -> some View {
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
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var loadMoreRow: some View {
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
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: - Bottom bar

    /// Record, unmissable at the thumb. Hidden while searching so it does not ride
    /// up on the keyboard, and replaced by the delete action while selecting.
    @ViewBuilder
    private var bottomBar: some View {
        if isSelecting {
            selectionBar
        } else if !isSearchPresented {
            VStack(spacing: 0) {
                Hairline()
                recordControl
                    .ledgerPageMargin()
                    .padding(.vertical, 10)
            }
            .ledgerBarBackground()
        }
    }

    @ViewBuilder
    private var recordControl: some View {
        if recorder.isRecording {
            Button {
                path.append(.record)
            } label: {
                HStack(spacing: 8) {
                    if recorder.captureState == .recording {
                        Circle()
                            .fill(Theme.onRecord)
                            .frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: "pause.fill")
                            .accessibilityHidden(true)
                    }
                    Text(recorder.captureState == .recording ? "Recording" : "Paused")
                    Text(recorder.formattedDuration)
                        .monospacedDigit()
                }
            }
            .buttonStyle(
                recorder.captureState == .recording
                    ? PrimaryButtonStyle(shape: .pill, fill: Theme.record, foreground: Theme.onRecord)
                    : PrimaryButtonStyle(shape: .pill)
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Return to recording")
            .accessibilityValue(recorder.formattedDuration)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("library.recording")
        } else {
            Button {
                startRecording(contentType: Self.defaultContentType)
            } label: {
                Label("Record", systemImage: "mic")
            }
            .buttonStyle(PrimaryButtonStyle(shape: .pill))
            .disabled(recorder.isStarting)
            .accessibilityHint("Starts recording from the microphone")
            .accessibilityIdentifier("library.record")
            // Optional and out of the way: most recordings never need a type.
            .contextMenu {
                Section("Record as") {
                    ForEach(RecordingContentType.all) { type in
                        Button {
                            startRecording(contentType: type.value)
                        } label: {
                            Label(type.title, systemImage: type.systemImage)
                        }
                    }
                }
            }
        }
    }

    private func startRecording(contentType: String) {
        recorder.start(contentType: contentType)
        Haptics.medium()
        path.append(.record)
    }

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
            .ledgerPageMargin()
            .padding(.vertical, 6)
        }
        .ledgerBarBackground()
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

private extension View {
    /// Plain rows on the paper with a hairline between them, not cards.
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
                    .accessibilityHidden(true)
            }
            Text(attention.text)
        }
        .font(.footnote)
        .foregroundStyle(attention.isWorking ? Theme.textSecondary : Theme.text)
    }
}

/// Mirrors `LibrarySummaryRow` for a recording the server does not list yet.
private struct DeviceRecordingRow: View {
    let recording: LocalRecording

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(recording.displayTitle)
                    .font(.ledgerRowTitle)
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Text(recording.formattedDuration)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if isFailed {
                    Image(systemName: "exclamationmark.circle")
                        .accessibilityHidden(true)
                } else if recording.isUploadInProgress {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Theme.textSecondary)
                        .accessibilityHidden(true)
                }
                Text(recording.recoveryDescription)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .font(.footnote)
            .foregroundStyle(isFailed ? Theme.text : Theme.textSecondary)
            if recording.state == .uploading {
                ProgressView(value: recording.uploadProgress ?? 0)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.vertical, 10)
    }

    private var isFailed: Bool {
        [.invalid, .uploadFailed].contains(recording.state)
    }
}

struct LibrarySummaryRow: View {
    let item: LibraryListItem
    let selectionState: Bool?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 10) {
            if let selectionState {
                Image(systemName: selectionState ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selectionState ? Theme.accent : Theme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                // At accessibility sizes a time beside the title would leave it one
                // word a line, so the time drops underneath and the title runs in full.
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(item.displayTitle)
                        .font(.ledgerRowTitle)
                        .foregroundStyle(Theme.text)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if item.favorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                            .accessibilityLabel("Favorite")
                    }
                    if !dynamicTypeSize.isAccessibilitySize, let timeText {
                        Text(timeText)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize()
                    }
                }

                if dynamicTypeSize.isAccessibilitySize, let timeText {
                    Text(timeText)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }

                if let displaySubtitle = item.displaySubtitle {
                    Text(displaySubtitle)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                if detailText != nil || attention != nil {
                    metaLine
                        .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var metaLine: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: 6))
        layout {
            if let detailText {
                Text(detailText)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            if detailText != nil, attention != nil, !dynamicTypeSize.isAccessibilitySize {
                Text(verbatim: "·")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
            }
            if let attention {
                AttentionLabel(attention: attention)
            }
        }
    }

    private var attention: ItemAttention? {
        ItemAttention(status: item.status)
    }

    private var timeText: String? {
        item.createdAt?.formatted(date: .omitted, time: .shortened)
    }

    private var detailText: String? {
        switch item.itemType {
        case "audio" where item.duration > 0:
            return LedgerFormat.duration(item.duration)
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
        .background(Theme.bg)
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
