import SwiftUI

struct LibraryView: View {
    @State private var service = MediaToolsService.shared
    @State private var selectedTab = 0
    @State private var searchText = ""
    @State private var searchResults: [Transcript] = []
    @State private var isSearching = false
    @State private var sortOrder: SortOrder = .newest
    @State private var statusFilter: StatusFilter = .all
    @State private var isSelecting = false
    @State private var selectedIds: Set<String> = []

    private let tabs = ["All", "Videos", "Audio", "PDFs"]

    enum SortOrder: String, CaseIterable {
        case newest = "Newest"
        case oldest = "Oldest"
        case title = "Title"
    }

    enum StatusFilter: String, CaseIterable {
        case all = "All"
        case completed = "Completed"
        case processing = "Processing"
        case failed = "Failed"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("Type", selection: $selectedTab) {
                ForEach(0..<tabs.count, id: \.self) { i in
                    Text(tabs[i]).tag(i)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Content
            List(selection: isSelecting ? $selectedIds : nil) {
                if isSearching && !searchText.isEmpty {
                    ForEach(searchResults) { item in
                        NavigationLink(value: LibraryItem.transcript(item)) {
                            TranscriptRow(transcript: item)
                        }
                    }
                } else {
                    if selectedTab == 0 || selectedTab == 1 {
                        let filtered = filteredTranscripts
                        if !filtered.isEmpty {
                            Section("Videos (\(filtered.count))") {
                                ForEach(filtered) { item in
                                    NavigationLink(value: LibraryItem.transcript(item)) {
                                        TranscriptRow(transcript: item)
                                    }
                                    .librarySwipeActions(itemType: "transcript", itemId: item.id) {
                                        try? await service.deleteTranscript(item.id)
                                        await service.loadTranscripts()
                                    }
                                }
                            }
                        }
                    }

                    if selectedTab == 0 || selectedTab == 2 {
                        let filtered = filteredAudio
                        if !filtered.isEmpty {
                            Section("Audio (\(filtered.count))") {
                                ForEach(filtered) { item in
                                    NavigationLink(value: LibraryItem.audio(item)) {
                                        AudioRow(audio: item)
                                    }
                                    .librarySwipeActions(itemType: "audio", itemId: item.id) {
                                        try? await service.deleteAudioItem(item.id)
                                        await service.loadAudioItems()
                                    }
                                }
                            }
                        }
                    }

                    if selectedTab == 0 || selectedTab == 3 {
                        let filtered = filteredPDFs
                        if !filtered.isEmpty {
                            Section("PDFs (\(filtered.count))") {
                                ForEach(filtered) { item in
                                    NavigationLink(value: LibraryItem.pdf(item)) {
                                        PDFRow(pdf: item)
                                    }
                                    .librarySwipeActions(itemType: "pdf", itemId: item.id) {
                                        try? await service.deletePDF(item.id)
                                        await service.loadPDFs()
                                    }
                                }
                            }
                        }
                    }

                    if totalCount == 0 && !service.isLoading {
                        ContentUnavailableView(
                            "No Items Yet",
                            systemImage: "tray",
                            description: Text("Transcribe a video, record audio, or upload a PDF to get started.")
                        )
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationDestination(for: LibraryItem.self) { item in
                ItemDetailView(item: item)
            }

            // Bulk action bar
            if isSelecting && !selectedIds.isEmpty {
                HStack {
                    Text("\(selectedIds.count) selected")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Button(role: .destructive) {
                        Task { await bulkDelete() }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.error)
                }
                .padding()
                .background(.bar)
            }
        }
        .navigationTitle("Library")
        .searchable(text: $searchText, prompt: "Search transcripts...")
        .onSubmit(of: .search) {
            Task { await search() }
        }
        .onChange(of: searchText) { _, newValue in
            if newValue.isEmpty {
                isSearching = false
                searchResults = []
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    // Sort
                    Menu {
                        ForEach(SortOrder.allCases, id: \.self) { order in
                            Button {
                                sortOrder = order
                            } label: {
                                HStack {
                                    Text(order.rawValue)
                                    if sortOrder == order {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }

                    // Filter
                    Menu {
                        ForEach(StatusFilter.allCases, id: \.self) { filter in
                            Button {
                                statusFilter = filter
                            } label: {
                                HStack {
                                    Text(filter.rawValue)
                                    if statusFilter == filter {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("Filter", systemImage: "line.3.horizontal.decrease")
                    }

                    Divider()

                    // Select mode
                    Button {
                        isSelecting.toggle()
                        if !isSelecting { selectedIds.removeAll() }
                    } label: {
                        Label(isSelecting ? "Cancel Selection" : "Select", systemImage: isSelecting ? "xmark" : "checkmark.circle")
                    }

                    Divider()

                    // PDF upload
                    NavigationLink(value: "pdf-upload") {
                        Label("Upload PDF", systemImage: "doc.badge.plus")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .navigationDestination(for: String.self) { value in
            if value == "pdf-upload" {
                PDFUploadView()
            }
        }
        .refreshable {
            await service.refreshAll()
        }
        .task {
            await service.refreshAll()
        }
    }

    // MARK: - Filtering & Sorting

    private var filteredTranscripts: [Transcript] {
        var items = service.transcripts
        if statusFilter != .all {
            items = items.filter { $0.status == statusFilter.rawValue.lowercased() }
        }
        return sorted(items, by: \.title, date: \.createdAt)
    }

    private var filteredAudio: [AudioTranscription] {
        var items = service.audioItems
        if statusFilter != .all {
            items = items.filter { $0.status == statusFilter.rawValue.lowercased() }
        }
        return sorted(items, by: \.title, date: \.createdAt)
    }

    private var filteredPDFs: [PDFExtraction] {
        var items = service.pdfItems
        if statusFilter != .all {
            items = items.filter { $0.status == statusFilter.rawValue.lowercased() }
        }
        return sorted(items, by: \.filename, date: \.createdAt)
    }

    private var totalCount: Int {
        (selectedTab == 0 || selectedTab == 1 ? filteredTranscripts.count : 0) +
        (selectedTab == 0 || selectedTab == 2 ? filteredAudio.count : 0) +
        (selectedTab == 0 || selectedTab == 3 ? filteredPDFs.count : 0)
    }

    private func sorted<T>(_ items: [T], by titlePath: KeyPath<T, String?>, date datePath: KeyPath<T, Date?>) -> [T] {
        switch sortOrder {
        case .newest:
            return items.sorted { ($0[keyPath: datePath] ?? .distantPast) > ($1[keyPath: datePath] ?? .distantPast) }
        case .oldest:
            return items.sorted { ($0[keyPath: datePath] ?? .distantPast) < ($1[keyPath: datePath] ?? .distantPast) }
        case .title:
            return items.sorted { ($0[keyPath: titlePath] ?? "") < ($1[keyPath: titlePath] ?? "") }
        }
    }

    // MARK: - Actions

    private func search() async {
        isSearching = true
        do {
            searchResults = try await service.searchTranscripts(searchText)
        } catch {
            print("Search failed: \(error)")
        }
    }

    private func bulkDelete() async {
        for id in selectedIds {
            // Try deleting from each type (API will 404 for wrong type, that's fine)
            try? await service.deleteTranscript(id)
            try? await service.deleteAudioItem(id)
            try? await service.deletePDF(id)
        }
        selectedIds.removeAll()
        isSelecting = false
        await service.refreshAll()
        Haptics.success()
    }
}

// MARK: - Library Item (for navigation)

enum LibraryItem: Hashable {
    case transcript(Transcript)
    case audio(AudioTranscription)
    case pdf(PDFExtraction)

    func hash(into hasher: inout Hasher) {
        switch self {
        case .transcript(let t): hasher.combine("t-\(t.id)")
        case .audio(let a): hasher.combine("a-\(a.id)")
        case .pdf(let p): hasher.combine("p-\(p.id)")
        }
    }

    static func == (lhs: LibraryItem, rhs: LibraryItem) -> Bool {
        lhs.hashValue == rhs.hashValue
    }
}

// MARK: - Row Views

struct TranscriptRow: View {
    let transcript: Transcript

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle.fill")
                .font(.title2)
                .foregroundStyle(Theme.videoColor)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(transcript.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)

                HStack(spacing: 8) {
                    StatusBadge(status: transcript.status)
                    if let wc = transcript.wordCount, wc > 0 {
                        Text("\(wc) words")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct AudioRow: View {
    let audio: AudioTranscription

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.fill")
                .font(.title2)
                .foregroundStyle(Theme.audioColor)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(audio.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)

                HStack(spacing: 8) {
                    StatusBadge(status: audio.status)
                    if let dur = audio.durationSeconds {
                        Text(formatDuration(dur))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins):\(String(format: "%02d", secs))"
    }
}

struct PDFRow: View {
    let pdf: PDFExtraction

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.fill")
                .font(.title2)
                .foregroundStyle(Theme.pdfColor)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(pdf.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)

                HStack(spacing: 8) {
                    StatusBadge(status: pdf.status)
                    if let pages = pdf.pageCount {
                        Text("\(pages) pages")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let status: String

    var body: some View {
        Text(status.capitalized)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor.opacity(0.15))
            .foregroundStyle(backgroundColor)
            .clipShape(Capsule())
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
