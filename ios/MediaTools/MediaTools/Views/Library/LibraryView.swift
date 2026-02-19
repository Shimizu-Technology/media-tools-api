import SwiftUI

struct LibraryView: View {
    @State private var service = MediaToolsService.shared
    @State private var selectedTab = 0
    @State private var searchText = ""
    @State private var searchResults: [Transcript] = []
    @State private var isSearching = false

    private let tabs = ["All", "Videos", "Audio", "PDFs"]

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
            List {
                if isSearching && !searchText.isEmpty {
                    ForEach(searchResults) { item in
                        TranscriptRow(transcript: item)
                    }
                } else {
                    if selectedTab == 0 || selectedTab == 1 {
                        if !service.transcripts.isEmpty {
                            Section("Videos") {
                                ForEach(service.transcripts) { item in
                                    NavigationLink(value: LibraryItem.transcript(item)) {
                                        TranscriptRow(transcript: item)
                                    }
                                }
                            }
                        }
                    }

                    if selectedTab == 0 || selectedTab == 2 {
                        if !service.audioItems.isEmpty {
                            Section("Audio") {
                                ForEach(service.audioItems) { item in
                                    NavigationLink(value: LibraryItem.audio(item)) {
                                        AudioRow(audio: item)
                                    }
                                }
                            }
                        }
                    }

                    if selectedTab == 0 || selectedTab == 3 {
                        if !service.pdfItems.isEmpty {
                            Section("PDFs") {
                                ForEach(service.pdfItems) { item in
                                    NavigationLink(value: LibraryItem.pdf(item)) {
                                        PDFRow(pdf: item)
                                    }
                                }
                            }
                        }
                    }

                    if service.transcripts.isEmpty && service.audioItems.isEmpty && service.pdfItems.isEmpty && !service.isLoading {
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
                NavigationLink(value: "pdf-upload") {
                    Image(systemName: "doc.badge.plus")
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

    private func search() async {
        isSearching = true
        do {
            searchResults = try await service.searchTranscripts(searchText)
        } catch {
            print("Search failed: \(error)")
        }
    }
}

// MARK: - Library Item (for navigation)

enum LibraryItem: Hashable {
    case transcript(Transcript)
    case audio(AudioTranscription)
    case pdf(PDFExtraction)

    // Hashable conformance by id
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
                .foregroundStyle(.teal)
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
                            .foregroundStyle(.secondary)
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
                .foregroundStyle(.orange)
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
                            .foregroundStyle(.secondary)
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
                .foregroundStyle(.red)
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
                            .foregroundStyle(.secondary)
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
        case "completed": .green
        case "processing", "pending": .orange
        case "failed": .red
        default: .gray
        }
    }
}
