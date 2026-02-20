import SwiftUI

struct ItemDetailView: View {
    let item: LibraryItem
    @State private var transcript: Transcript?
    @State private var audio: AudioTranscription?
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
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showChat) {
            NavigationStack {
                ChatView(itemType: chatItemType, itemId: itemId)
                    .navigationTitle("Chat")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showChat = false }
                        }
                    }
            }
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
                        .font(.title3.weight(.semibold))
                    HStack(spacing: 8) {
                        StatusBadge(status: statusText)
                        if let wc = wordCount, wc > 0 {
                            Text("\(wc) words")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        if let dur = audioDuration {
                            Text(formatDuration(dur))
                                .font(.caption)
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
            .disabled(isLoadingSummary)
        }
    }

    // MARK: - Summary Content Type

    @ViewBuilder
    private var summaryTypeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Summary Style")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(summaryTypes, id: \.0) { type in
                        Button {
                            summaryContentType = type.0
                        } label: {
                            Text(type.1)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(summaryContentType == type.0 ? Theme.brand500 : Color.secondary.opacity(0.1))
                                .foregroundStyle(summaryContentType == type.0 ? .white : .primary)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
    }

    // MARK: - Audio Player

    @ViewBuilder
    private var audioPlayerSection: some View {
        if case .audio(let a) = item, a.isComplete {
            AudioPlayerView(audioId: a.id)
        }
    }

    // MARK: - Summary

    @ViewBuilder
    private var summarySection: some View {
        if let summary, let summaryText = summary.summary {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Theme.brand500)
                    Text("Summary")
                        .font(.headline)
                }

                Text(summaryText)
                    .font(.body)
                    .foregroundStyle(.primary.opacity(0.85))
                    .textSelection(.enabled)

                if let points = summary.keyPoints, !points.isEmpty {
                    Text("Key Points")
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 4)

                    ForEach(points, id: \.self) { point in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 5))
                                .padding(.top, 7)
                                .foregroundStyle(Theme.brand500)
                            Text(point)
                                .font(.subheadline)
                        }
                    }
                }

                if let actions = summary.actionItems, !actions.isEmpty {
                    Text("Action Items")
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 4)

                    ForEach(actions, id: \.self) { action in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark.square")
                                .font(.caption)
                                .foregroundStyle(Theme.brand500)
                                .padding(.top, 2)
                            Text(action)
                                .font(.subheadline)
                        }
                    }
                }

                if let topics = summary.topics, !topics.isEmpty {
                    Text("Topics")
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 4)

                    FlowLayout(spacing: 6) {
                        ForEach(topics, id: \.self) { topic in
                            Text(topic)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Theme.brand500.opacity(0.1))
                                .foregroundStyle(Theme.brand500)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            .padding()
            .background(.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Transcript Text

    @ViewBuilder
    private var transcriptSection: some View {
        if let text = contentText, !text.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Transcript")
                    .font(.headline)

                Text(text)
                    .font(.body)
                    .foregroundStyle(.primary.opacity(0.85))
                    .textSelection(.enabled)
            }
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
        transcript?.transcriptText ?? audio?.transcriptText ?? nil
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
            case .pdf:
                break
            }
        } catch {
            print("Failed to load detail: \(error)")
        }
    }

    private func generateSummary() async {
        isLoadingSummary = true
        Haptics.light()
        defer { isLoadingSummary = false }
        do {
            summary = try await service.getSummary(
                transcriptId: itemId,
                contentType: summaryContentType == "general" ? nil : summaryContentType
            )
            Haptics.success()
        } catch {
            Haptics.error()
            print("Summary failed: \(error)")
        }
    }
}

// MARK: - Export Sheet

struct ExportSheet: View {
    let text: String
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    shareText(text, as: "\(title).txt")
                } label: {
                    Label("Plain Text (.txt)", systemImage: "doc.text")
                }

                Button {
                    let md = "# \(title)\n\n\(text)"
                    shareText(md, as: "\(title).md")
                } label: {
                    Label("Markdown (.md)", systemImage: "doc.richtext")
                }

                Button {
                    let json: [String: Any] = ["title": title, "text": text]
                    if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
                       let jsonString = String(data: data, encoding: .utf8) {
                        shareText(jsonString, as: "\(title).json")
                    }
                } label: {
                    Label("JSON (.json)", systemImage: "curlybraces")
                }
            }
            .navigationTitle("Export As")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
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
