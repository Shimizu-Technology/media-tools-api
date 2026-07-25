import SwiftUI

struct ItemDetailView: View {
    let item: LibraryItem
    @Environment(\.openURL) private var openURL
    @State private var transcript: Transcript?
    @State private var audio: AudioTranscription?
    @State private var pdf: PDFExtraction?
    @State private var segments: [MediaSegment] = []
    @State private var audioSeekTime: TimeInterval?
    @State private var scrollTarget: String?
    @State private var showChat = false
    @State private var showAddToCollection = false
    @State private var summary: Summary?
    @State private var isLoadingSummary = false
    @State private var summaryContentType = "general"
    @State private var showExportSheet = false
    @State private var exportText = ""

    private let service = MediaToolsService.shared

    private let summaryTypes = [
        ("general", "General"),
        ("tutorial", "Tutorial"),
        ("lecture", "Lecture"),
        ("podcast", "Podcast"),
        ("conference", "Conference"),
        ("review", "Review"),
        ("news", "News"),
    ]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerSection
                    actionButtons
                    summaryTypeSection
                    audioPlayerSection
                    summarySection
                    transcriptSection
                }
                .padding()
            }
            .onChange(of: scrollTarget) {
                guard let scrollTarget else { return }
                withAnimation(Theme.springGentle) {
                    proxy.scrollTo(scrollTarget, anchor: .center)
                }
                self.scrollTarget = nil
            }
        }
        .background(Theme.surface)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showChat) {
            NavigationStack {
                ChatView(itemType: chatItemType, itemId: itemId, onCitationTap: handleCitation)
                    .navigationTitle("Chat")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showChat = false }
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showAddToCollection) {
            AddToCollectionSheet(
                itemType: chatItemType,
                itemId: itemId,
                onDismiss: { showAddToCollection = false }
            )
        }
        .sheet(isPresented: $showExportSheet) {
            ExportSheet(text: exportText, title: title)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showAddToCollection = true
                    } label: {
                        Label("Add to Collection", systemImage: "folder.badge.plus")
                    }
                    if let text = contentText {
                        Button {
                            UIPasteboard.general.string = text
                            Haptics.success()
                        } label: {
                            Label("Copy Text", systemImage: "doc.on.doc")
                        }
                        Button {
                            exportText = text
                            showExportSheet = true
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task { await loadDetail() }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: iconName)
                    .font(.title)
                    .foregroundStyle(iconColor)

                VStack(alignment: .leading) {
                    Text(title)
                        .font(Theme.heading(18))
                        .foregroundStyle(Theme.textPrimary)
                    HStack(spacing: 8) {
                        StatusBadge(status: statusText)
                        if let wc = wordCount, wc > 0 {
                            Text("\(wc) words")
                                .font(Theme.caption())
                                .foregroundStyle(Theme.textSecondary)
                        }
                        if let dur = audioDuration {
                            Text(formatDuration(dur))
                                .font(Theme.caption())
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                showChat = true
            } label: {
                Label("Chat", systemImage: "bubble.left.and.bubble.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.brand500)

            Button {
                Task { await generateSummary() }
            } label: {
                if isLoadingSummary {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Summarize", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .tint(Theme.brand400)
            .disabled(isLoadingSummary || !canSummarize)
        }
    }

    private var canSummarize: Bool {
        if case .pdf = item { return false }
        return true
    }

    // MARK: - Summary Content Type

    @ViewBuilder
    private var summaryTypeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(text: "Summary Style", icon: "sparkles")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(summaryTypes, id: \.0) { type in
                        Button {
                            withAnimation(Theme.springSnappy) {
                                summaryContentType = type.0
                            }
                        } label: {
                            Text(type.1)
                                .chipStyle(isSelected: summaryContentType == type.0)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Audio Player

    @ViewBuilder
    private var audioPlayerSection: some View {
        if let audio, audio.isComplete {
            AudioPlayerView(audioId: audio.id, seekTime: $audioSeekTime)
                .id("audio-player")
        }
    }

    // MARK: - Summary

    @ViewBuilder
    private var summarySection: some View {
        if let summary, let summaryText = summary.summary {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Theme.brand400)
                    Text("Summary")
                        .font(Theme.heading(16))
                        .foregroundStyle(Theme.textPrimary)
                }

                Text(summaryText)
                    .font(Theme.body())
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)

                CitationChips(
                    citations: summary.evidence?.summary ?? [],
                    onTap: handleCitation
                )

                if let points = summary.keyPoints, !points.isEmpty {
                    Text("Key Points")
                        .font(Theme.body(14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.top, 4)

                    ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 5))
                                    .padding(.top, 7)
                                    .foregroundStyle(Theme.brand500)
                                Text(point)
                                    .font(Theme.body(14))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            CitationChips(
                                citations: summary.evidence?.keyPoints?[safe: index] ?? [],
                                onTap: handleCitation
                            )
                        }
                    }
                }

                if let actions = summary.actionItems, !actions.isEmpty {
                    Text("Action Items")
                        .font(Theme.body(14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.top, 4)

                    ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "checkmark.square")
                                    .font(.caption)
                                    .foregroundStyle(Theme.brand500)
                                    .padding(.top, 2)
                                Text(action)
                                    .font(Theme.body(14))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            CitationChips(
                                citations: summary.evidence?.actionItems?[safe: index] ?? [],
                                onTap: handleCitation
                            )
                        }
                    }
                }

                if let topics = summary.topics, !topics.isEmpty {
                    Text("Topics")
                        .font(Theme.body(14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.top, 4)

                    FlowLayout(spacing: 6) {
                        ForEach(topics, id: \.self) { topic in
                            Text(topic)
                                .font(Theme.caption())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Theme.brand500.opacity(0.1))
                                .foregroundStyle(Theme.brand400)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            .accentCardStyle()
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    // MARK: - Transcript Text

    @ViewBuilder
    private var transcriptSection: some View {
        if let text = contentText, !text.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(text: "Transcript", icon: "doc.text")

                if segments.isEmpty {
                    Text(text)
                        .font(Theme.body())
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(segments) { segment in
                            Button {
                                handleSegment(segment)
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Text(segment.locatorLabel)
                                        .font(.caption.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(iconColor)
                                        .frame(minWidth: 52, alignment: .leading)

                                    Text(segment.text)
                                        .font(Theme.body())
                                        .foregroundStyle(Theme.textSecondary)
                                        .multilineTextAlignment(.leading)

                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(segment.id)

                            if segment.id != segments.last?.id {
                                Divider()
                                    .overlay(Theme.borderSubtle)
                            }
                        }
                    }
                }
            }
            .cardStyle()
        }
    }

    // MARK: - Helpers

    private var title: String {
        switch item {
        case .transcript(let t): t.displayTitle
        case .audio(let a): a.displayTitle
        case .pdf(let p): p.displayTitle
        }
    }

    private var itemId: String {
        switch item {
        case .transcript(let t): t.id
        case .audio(let a): a.id
        case .pdf(let p): p.id
        }
    }

    private var chatItemType: String {
        switch item {
        case .transcript: "transcript"
        case .audio: "audio"
        case .pdf: "pdf"
        }
    }

    private var iconName: String {
        switch item {
        case .transcript: "play.rectangle.fill"
        case .audio: "mic.fill"
        case .pdf: "doc.fill"
        }
    }

    private var iconColor: Color {
        switch item {
        case .transcript: Theme.brand500
        case .audio: Theme.audioColor
        case .pdf: Theme.error
        }
    }

    private var statusText: String {
        switch item {
        case .transcript(let t): t.status
        case .audio(let a): a.status
        case .pdf(let p): p.status
        }
    }

    private var wordCount: Int? {
        switch item {
        case .transcript(let t): t.wordCount
        case .audio(let a): a.wordCount
        case .pdf(let p): p.wordCount
        }
    }

    private var audioDuration: Double? {
        if case .audio(let a) = item { return a.duration }
        return nil
    }

    private var contentText: String? {
        transcript?.transcriptText ?? audio?.transcriptText ?? pdf?.textContent ?? nil
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins):\(String(format: "%02d", secs))"
    }

    private func loadDetail() async {
        do {
            switch item {
            case .transcript(let t):
                transcript = try await service.getTranscript(t.id)
            case .audio(let a):
                audio = try await service.getAudioItem(a.id)
                if let audio, audio.summaryStatus == "completed" {
                    summary = Summary(
                        id: audio.id,
                        transcriptId: nil,
                        summaryText: audio.summaryText,
                        keyPoints: audio.keyPoints,
                        actionItems: audio.actionItems,
                        topics: nil,
                        status: audio.summaryStatus,
                        message: nil,
                        errorMessage: audio.summaryErrorMessage,
                        evidence: audio.summaryEvidence
                    )
                }
            case .pdf(let p):
                pdf = try await service.getPDF(p.id)
            }
        } catch {
            print("Failed to load detail: \(error)")
        }

        do {
            segments = try await service.getMediaSegments(itemType: chatItemType, itemId: itemId)
        } catch {
            // Legacy items may predate source segments; plain text remains usable.
            print("Failed to load source segments: \(error)")
        }
    }

    private func handleSegment(_ segment: MediaSegment) {
        handleCitation(Citation(
            segmentId: segment.id,
            itemType: segment.itemType,
            itemId: segment.itemId,
            itemTitle: title,
            startMs: segment.startMs,
            endMs: segment.endMs,
            pageNumber: segment.pageNumber
        ))
    }

    private func handleCitation(_ citation: Citation) {
        guard citation.itemType == chatItemType, citation.itemId == itemId else {
            return
        }

        if citation.itemType == "transcript",
           let startMS = citation.startMs,
           let youtubeURL = transcript?.youtubeUrl,
           var components = URLComponents(string: youtubeURL) {
            var items = components.queryItems ?? []
            items.removeAll { $0.name == "t" || $0.name == "start" }
            items.append(URLQueryItem(name: "t", value: "\(startMS / 1_000)s"))
            components.queryItems = items
            if let url = components.url {
                openURL(url)
            }
            return
        }

        if citation.itemType == "audio", let startMS = citation.startMs {
            audioSeekTime = TimeInterval(startMS) / 1_000
            scrollTarget = "audio-player"
            showChat = false
            return
        }

        scrollTarget = citation.segmentId
        showChat = false
    }

    private func generateSummary() async {
        isLoadingSummary = true
        Haptics.light()
        defer { isLoadingSummary = false }
        do {
            let selectedContentType = summaryContentType == "general" ? nil : summaryContentType
            let result: Summary
            switch item {
            case .transcript:
                result = try await service.getSummary(transcriptId: itemId, contentType: selectedContentType)
            case .audio:
                result = try await service.summarizeAudio(audioId: itemId, contentType: selectedContentType)
            case .pdf:
                throw APIError.httpError(statusCode: 400, message: "PDF summaries are not available yet")
            }
            withAnimation(Theme.springGentle) {
                summary = result
            }
            Haptics.success()
        } catch {
            Haptics.error()
            print("Summary failed: \(error)")
        }
    }
}

// MARK: - Evidence Links

struct CitationChips: View {
    let citations: [Citation]
    let onTap: (Citation) -> Void

    var body: some View {
        if !citations.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(citations, id: \.self) { citation in
                    Button {
                        onTap(citation)
                    } label: {
                        Label(citation.locatorLabel, systemImage: citation.pageNumber == nil ? "play.fill" : "doc.text")
                            .font(Theme.caption(11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .frame(minHeight: 44)
                            .background(Theme.brand500.opacity(0.12))
                            .foregroundStyle(Theme.brand400)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(Theme.brand500.opacity(0.25), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open source at \(citation.locatorLabel)")
                }
            }
        }
    }
}

extension Swift.Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Export Sheet

struct ExportSheet: View {
    let text: String
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Button {
                    shareText(text, as: "\(title).txt")
                } label: {
                    Label("Plain Text (.txt)", systemImage: "doc.text")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .cardStyle(padding: 14)

                Button {
                    let md = "# \(title)\n\n\(text)"
                    shareText(md, as: "\(title).md")
                } label: {
                    Label("Markdown (.md)", systemImage: "doc.richtext")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .cardStyle(padding: 14)

                Button {
                    let json: [String: Any] = ["title": title, "text": text]
                    if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
                       let jsonString = String(data: data, encoding: .utf8) {
                        shareText(jsonString, as: "\(title).json")
                    }
                } label: {
                    Label("JSON (.json)", systemImage: "curlybraces")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .cardStyle(padding: 14)

                Spacer()
            }
            .padding()
            .background(Theme.surface)
            .foregroundStyle(Theme.textPrimary)
            .navigationTitle("Export As")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }

    private func shareText(_ content: String, as filename: String) {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? content.write(to: tempURL, atomically: true, encoding: .utf8)

        let activityVC = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = windowScene.windows.first?.rootViewController {
            root.present(activityVC, animated: true)
        }
        dismiss()
    }
}

// MARK: - Flow Layout (for topic chips)

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (positions, CGSize(width: maxX, height: y + rowHeight))
    }
}
