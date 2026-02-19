import SwiftUI

struct ItemDetailView: View {
    let item: LibraryItem
    @State private var transcript: Transcript?
    @State private var audio: AudioTranscription?
    @State private var showChat = false
    @State private var showSummary = false
    @State private var summary: Summary?
    @State private var isLoadingSummary = false

    private let service = MediaToolsService.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                headerSection

                // Action buttons
                actionButtons

                // Content
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

                // Summary
                if let summary, let summaryText = summary.summary {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Summary")
                            .font(.headline)

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
                                        .foregroundStyle(.teal)
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
                                        .foregroundStyle(.teal)
                                        .padding(.top, 2)
                                    Text(action)
                                        .font(.subheadline)
                                }
                            }
                        }
                    }
                }
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
        .task { await loadDetail() }
    }

    // MARK: - Subviews

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: iconName)
                    .font(.title)
                    .foregroundStyle(iconColor)

                VStack(alignment: .leading) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let wc = wordCount, wc > 0 {
                Text("\(wc) words")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                showChat = true
            } label: {
                Label("Chat", systemImage: "bubble.left.and.bubble.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)

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

            // Copy button
            if let text = contentText {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.bordered)
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
        case .transcript: .teal
        case .audio: .orange
        case .pdf: .red
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

    private var contentText: String? {
        transcript?.transcriptText ?? audio?.transcriptText ?? nil
    }

    private func loadDetail() async {
        do {
            switch item {
            case .transcript(let t):
                transcript = try await service.getTranscript(t.id)
            case .audio(let a):
                audio = try await service.getAudioItem(a.id)
            case .pdf:
                break // PDFs don't have a separate detail endpoint yet
            }
        } catch {
            print("Failed to load detail: \(error)")
        }
    }

    private func generateSummary() async {
        isLoadingSummary = true
        defer { isLoadingSummary = false }
        do {
            summary = try await service.getSummary(transcriptId: itemId)
        } catch {
            print("Summary failed: \(error)")
        }
    }
}
