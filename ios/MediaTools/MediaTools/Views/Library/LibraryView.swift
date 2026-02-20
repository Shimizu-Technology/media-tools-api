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
    @State private var hasAppeared = false

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
            // Tab chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(0..<tabs.count, id: \.self) { i in
                        TabChip(title: tabs[i], isSelected: selectedTab == i) {
                            withAnimation(Theme.springSnappy) {
                                selectedTab = i
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }

            // Content
            ScrollView {
                LazyVStack(spacing: 12) {
                    if isSearching && !searchText.isEmpty {
                        ForEach(searchResults) { item in
                            NavigationLink(value: LibraryItem.transcript(item)) {
                                TranscriptRow(transcript: item)
                                    .cardStyle(padding: 12)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal)
                    } else {
                        if selectedTab == 0 || selectedTab == 1 {
                            let filtered = filteredTranscripts
                            if !filtered.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    SectionHeader(text: "Videos (\(filtered.count))", icon: "play.rectangle.fill")
                                        .padding(.horizontal)

                                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                                        NavigationLink(value: LibraryItem.transcript(item)) {
                                            TranscriptRow(transcript: item)
                                                .cardStyle(padding: 12)
                                        }
                                        .buttonStyle(.plain)
                                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                                        .librarySwipeActions(itemType: "transcript", itemId: item.id) {
                                            try? await service.deleteTranscript(item.id)
                                            await service.loadTranscripts()
                                        }
                                    }
                                    .padding(.horizontal)
                                }
                            }
                        }

                        if selectedTab == 0 || selectedTab == 2 {
                            let filtered = filteredAudio
                            if !filtered.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    SectionHeader(text: "Audio (\(filtered.count))", icon: "mic.fill")
                                        .padding(.horizontal)

                                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                                        NavigationLink(value: LibraryItem.audio(item)) {
                                            AudioRow(audio: item)
                                                .cardStyle(padding: 12)
                                        }
                                        .buttonStyle(.plain)
                                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                                        .librarySwipeActions(itemType: "audio", itemId: item.id) {
                                            try? await service.deleteAudioItem(item.id)
                                            await service.loadAudioItems()
                                        }
                                    }
                                    .padding(.horizontal)
                                }
                            }
                        }

                        if selectedTab == 0 || selectedTab == 3 {
                            let filtered = filteredPDFs
                            if !filtered.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    SectionHeader(text: "PDFs (\(filtered.count))", icon: "doc.fill")
                                        .padding(.horizontal)

                                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                                        NavigationLink(value: LibraryItem.pdf(item)) {
                                            PDFRow(pdf: item)
                                                .cardStyle(padding: 12)
                                        }
                                        .buttonStyle(.plain)
                                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                                        .librarySwipeActions(itemType: "pdf", itemId: item.id) {
                                            try? await service.deletePDF(item.id)
                                            await service.loadPDFs()
                                        }
                                    }
                                    .padding(.horizontal)
                                }
                            }
                        }

                        if totalCount == 0 && !service.isLoading {
                            ContentUnavailableView(
                                "No Items Yet",
                                systemImage: "tray",
                                description: Text("Transcribe a video, record audio, or upload a PDF to get started.")
                            )
                            .padding(.top, 60)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .navigationDestination(for: LibraryItem.self) { item in
                ItemDetailView(item: item)
            }

            // Bulk action bar
            if isSelecting && !selectedIds.isEmpty {
                HStack {
                    Text("\(selectedIds.count) selected")
                        .font(Theme.body(14, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
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
                .background(Theme.surfaceElevated)
            }
        }
        .background(Theme.surface)
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

                    Button {
                        withAnimation(Theme.springSnappy) {
                            isSelecting.toggle()
                            if !isSelecting { selectedIds.removeAll() }
                        }
                    } label: {
                        Label(isSelecting ? "Cancel Selection" : "Select", systemImage: isSelecting ? "xmark" : "checkmark.circle")
                    }

                    Divider()

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
            withAnimation(Theme.springGentle) {
                hasAppeared = true
            }
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
                    .font(Theme.body(15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    StatusBadge(status: transcript.status)
                    if let wc = transcript.wordCount, wc > 0 {
                        Text("\(wc) words")
                            .font(Theme.caption())
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
        }
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
                    .font(Theme.body(15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    StatusBadge(status: audio.status)
                    if let dur = audio.duration {
                        Text(formatDuration(dur))
                            .font(Theme.caption())
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
        }
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
                    .font(Theme.body(15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    StatusBadge(status: pdf.status)
                    if let pages = pdf.pageCount {
                        Text("\(pages) pages")
                            .font(Theme.caption())
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
        }
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
