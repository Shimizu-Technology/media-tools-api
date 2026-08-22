import SwiftUI

private enum TranscriptViewMode: String, CaseIterable, Identifiable {
    case readable = "Readable"
    case timestamps = "Timestamps"
    case original = "Original"

    var id: String { rawValue }

    var title: String {
        self == .readable ? "Transcript" : rawValue
    }
}

struct ItemDetailView: View {
    let item: LibraryItem
    @Environment(\.openURL) private var openURL
    @Environment(AIProcessingConsentManager.self) private var aiProcessingConsent
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
    @State private var preferences = LibraryPreferences(favorite: false, archived: false, tags: [])
    @State private var tagInput = ""
    @State private var isSavingPreferences = false
    @State private var showRenameSheet = false
    @State private var renameValue = ""
    @State private var isRenaming = false
    @State private var isRetrying = false
    @State private var transcriptViewMode: TranscriptViewMode = .readable
    @State private var isFormattingTranscript = false
    @State private var detailError: String?
    @State private var pollingWarning: String?
    @State private var detailPollingTask: Task<Void, Never>?

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
                    if let detailError {
                        detailErrorBanner(detailError)
                    }
                    if let pollingWarning {
                        pollingWarningBanner(pollingWarning)
                    }
                    processingSection
                    actionButtons
                    preferencesSection
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
        .sheet(isPresented: $showRenameSheet) {
            renameSheet
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if isAudioItem {
                        Button {
                            beginRename()
                        } label: {
                            Label("Rename Recording", systemImage: "pencil")
                        }
                    }
                    Button {
                        Task {
                            await savePreferences(
                                UpdateLibraryPreferencesRequest(favorite: !preferences.favorite)
                            )
                        }
                    } label: {
                        Label(
                            preferences.favorite ? "Remove Star" : "Star",
                            systemImage: preferences.favorite ? "star.slash" : "star"
                        )
                    }
                    Button {
                        Task {
                            await savePreferences(
                                UpdateLibraryPreferencesRequest(archived: !preferences.archived)
                            )
                        }
                    } label: {
                        Label(
                            preferences.archived ? "Unarchive" : "Archive",
                            systemImage: preferences.archived ? "tray.and.arrow.up" : "archivebox"
                        )
                    }
                    Button {
                        showAddToCollection = true
                    } label: {
                        Label("Add to Collection", systemImage: "folder.badge.plus")
                    }
                    if let text = visibleTranscriptText {
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
        .onChange(of: audio?.hasDistinctReadableTranscript) { _, hasDistinctOriginal in
            if hasDistinctOriginal != true, transcriptViewMode == .original {
                transcriptViewMode = .readable
            }
        }
        .onDisappear { detailPollingTask?.cancel() }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: iconName)
                    .font(.title)
                    .foregroundStyle(iconColor)

                VStack(alignment: .leading) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title)
                            .font(Theme.heading(18))
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if isAudioItem {
                            Button(action: beginRename) {
                                Image(systemName: "pencil")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.brand400)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Rename recording")
                        }
                    }
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
                        if preferences.favorite {
                            Image(systemName: "star.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.warning)
                                .accessibilityLabel("Starred")
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
                Task {
                    guard await aiProcessingConsent.requestPermission() else { return }
                    showChat = true
                }
            } label: {
                Label("Chat", systemImage: "bubble.left.and.bubble.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.brand500)
            .disabled(!canUseContentActions)

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
        return canUseContentActions
    }

    private var canUseContentActions: Bool {
        !["pending", "processing", "failed"].contains(statusText)
    }

    // MARK: - Processing state

    @ViewBuilder
    private var processingSection: some View {
        if let audio, ["pending", "processing"].contains(audio.status) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ProgressView()
                        .tint(Theme.brand400)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(audio.processingDescription)
                            .font(Theme.body(15, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("You can leave this screen. Media Tools will keep working in the background.")
                            .font(Theme.caption())
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                if let progress = audio.processingProgress, progress > 0 {
                    ProgressView(value: Double(progress), total: 100)
                        .tint(Theme.brand400)
                        .accessibilityLabel("Transcription progress")
                        .accessibilityValue("\(progress) percent")
                }
            }
            .accentCardStyle()
        } else if let audio, audio.status == "failed" {
            VStack(alignment: .leading, spacing: 12) {
                Label("Transcription needs attention", systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.error)
                Text(audio.errorMessage ?? "The recording could not be transcribed.")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textSecondary)
                if audio.isRetryable {
                    Button {
                        Task { await retryAudioTranscription() }
                    } label: {
                        if isRetrying {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Label("Retry Transcription", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brand500)
                    .disabled(isRetrying)
                }
            }
            .cardStyle()
        }
    }

    // MARK: - Library preferences

    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(text: "Organize", icon: "tag")
                Spacer()
                if isSavingPreferences {
                    ProgressView().tint(Theme.brand400)
                }
            }

            if !preferences.tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(preferences.tags, id: \.self) { tag in
                        Button {
                            Task { await removeTag(tag) }
                        } label: {
                            HStack(spacing: 5) {
                                Text(tag)
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .font(Theme.caption(12, weight: .semibold))
                            .foregroundStyle(Theme.brand400)
                            .padding(.leading, 11)
                            .padding(.trailing, 9)
                            .frame(minHeight: 44)
                            .background(Theme.brand500.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isSavingPreferences)
                        .accessibilityLabel("Remove \(tag) tag")
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Add a tag", text: $tagInput)
                    .textFieldStyle(.themed)
                    .submitLabel(.done)
                    .onSubmit { Task { await addTag() } }
                    .onChange(of: tagInput) { _, value in
                        if value.count > 40 { tagInput = String(value.prefix(40)) }
                    }
                Button("Add") { Task { await addTag() } }
                    .font(Theme.body(14, weight: .semibold))
                    .frame(minWidth: 56, minHeight: 44)
                    .foregroundStyle(Theme.brand400)
                    .disabled(tagInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSavingPreferences)
            }
        }
        .cardStyle()
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
            AudioPlayerView(
                audioId: audio.id,
                knownDuration: audio.duration,
                seekTime: $audioSeekTime
            )
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
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(text: "Transcript", icon: "doc.text")

                if isAudioItem {
                    Picker("Transcript view", selection: $transcriptViewMode) {
                        ForEach(availableTranscriptViewModes) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(transcriptViewDescription)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textMuted)

                    if transcriptViewMode == .readable {
                        transcriptFormattingState
                    }
                }

                if isAudioItem && transcriptViewMode == .timestamps && !segments.isEmpty {
                    timestampedTranscript
                } else if !isAudioItem && !segments.isEmpty {
                    timestampedTranscript
                } else {
                    Text(visibleTranscriptText ?? text)
                        .font(Theme.body())
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                }
            }
            .cardStyle()
        }
    }

    private var timestampedTranscript: some View {
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

    @ViewBuilder
    private var transcriptFormattingState: some View {
        if let audio {
            switch audio.formattingStatus ?? "none" {
            case "pending", "processing":
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(Theme.brand500)
                    Text("Formatting for readability… Your transcript is available now.")
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textSecondary)
                }
            case "failed":
                VStack(alignment: .leading, spacing: 10) {
                    Text(audio.formattingErrorMessage ?? "Readable formatting could not finish. Your transcript is shown unchanged.")
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textSecondary)
                    Button {
                        Task { await formatTranscriptForReadability() }
                    } label: {
                        if isFormattingTranscript {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Label("Try Again", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.brand500)
                    .disabled(isFormattingTranscript)
                }
                .padding(12)
                .background(Theme.warning.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            case "none":
                VStack(alignment: .leading, spacing: 10) {
                    Text("This recording predates readable formatting.")
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textSecondary)
                    Button {
                        Task { await formatTranscriptForReadability() }
                    } label: {
                        if isFormattingTranscript {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Label("Improve Readability", systemImage: "sparkles")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brand500)
                    .disabled(isFormattingTranscript)
                }
                .padding(12)
                .background(Theme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            default:
                EmptyView()
            }
        }
    }

    private var transcriptViewDescription: String {
        switch transcriptViewMode {
        case .readable:
            audio?.hasDistinctReadableTranscript == true
                ? "Cleaned punctuation and paragraphs with every spoken word preserved."
                : "Every spoken word from this recording."
        case .timestamps:
            "Tap a timestamp to play that moment."
        case .original:
            "Untouched speech-to-text from the transcription service."
        }
    }

    private var availableTranscriptViewModes: [TranscriptViewMode] {
        var modes: [TranscriptViewMode] = [.readable]
        if !segments.isEmpty {
            modes.append(.timestamps)
        }
        if audio?.hasDistinctReadableTranscript == true {
            modes.append(.original)
        }
        return modes
    }

    // MARK: - Helpers

    private var title: String {
        switch item {
        case .transcript(let t): t.displayTitle
        case .audio(let a): (audio ?? a).displayTitle
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
        case .audio(let a): (audio ?? a).status
        case .pdf(let p): p.status
        }
    }

    private var wordCount: Int? {
        switch item {
        case .transcript(let t): t.wordCount
        case .audio(let a): (audio ?? a).wordCount
        case .pdf(let p): p.wordCount
        }
    }

    private var audioDuration: Double? {
        if case .audio(let a) = item { return (audio ?? a).duration }
        return nil
    }

    private var isAudioItem: Bool {
        if case .audio = item { return true }
        return false
    }

    private var itemReference: LibraryReference {
        LibraryReference(itemType: chatItemType, itemId: itemId)
    }

    private var contentText: String? {
        transcript?.transcriptText ?? audio?.readableTranscriptText ?? pdf?.textContent ?? nil
    }

    private var visibleTranscriptText: String? {
        guard let audio else { return contentText }
        switch transcriptViewMode {
        case .readable:
            return audio.readableTranscriptText
        case .original:
            return audio.transcriptText
        case .timestamps:
            let timestamped = segments.compactMap { segment -> String? in
                guard segment.startMs != nil else { return nil }
                return "[\(segment.locatorLabel)] \(segment.text)"
            }.joined(separator: "\n")
            return timestamped.isEmpty ? audio.transcriptText : timestamped
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins):\(String(format: "%02d", secs))"
    }

    private func loadDetail() async {
        detailError = nil
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
                if let audio,
                   ["pending", "processing"].contains(audio.status)
                    || ["pending", "processing"].contains(audio.formattingStatus ?? "none") {
                    startDetailPolling()
                }
            case .pdf(let p):
                pdf = try await service.getPDF(p.id)
            }
        } catch {
            detailError = error.localizedDescription
        }

        do {
            preferences = try await service.getLibraryPreferences(itemReference)
        } catch {
            // Content remains fully usable if preference metadata is briefly
            // unavailable; expose the error without replacing the detail.
            detailError = error.localizedDescription
        }

        do {
            segments = try await service.getMediaSegments(itemType: chatItemType, itemId: itemId)
        } catch {
            // Legacy items may predate source segments; plain text remains usable.
            print("Failed to load source segments: \(error)")
        }
    }

    @ViewBuilder
    private func detailErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Theme.error)
            Text(message)
                .font(Theme.caption())
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
            Button {
                detailError = nil
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textMuted)
            .accessibilityLabel("Dismiss error")
        }
        .cardStyle(padding: 12)
    }

    @ViewBuilder
    private func pollingWarningBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 3) {
                Text("Connection interrupted")
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(message)
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .cardStyle(padding: 12)
    }

    @ViewBuilder
    private var renameSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Use a name you will recognize in search, exports, and collections.")
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.textSecondary)

                TextField("Recording title", text: $renameValue)
                    .textFieldStyle(.themed)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.done)
                    .onSubmit { Task { await renameAudio() } }
                    .accessibilityIdentifier("recording.rename.field")

                if let detailError {
                    Text(detailError)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.error)
                }
                Spacer(minLength: 0)
            }
            .padding()
            .background(Theme.surface)
            .navigationTitle("Rename Recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showRenameSheet = false }
                        .disabled(isRenaming)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await renameAudio() }
                    } label: {
                        if isRenaming { ProgressView() } else { Text("Save") }
                    }
                    .disabled(renameValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRenaming)
                    .accessibilityIdentifier("recording.rename.save")
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.height(250)])
    }

    private func beginRename() {
        renameValue = title
        detailError = nil
        showRenameSheet = true
    }

    private func renameAudio() async {
        guard isAudioItem else { return }
        let nextName = renameValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nextName.isEmpty else { return }
        isRenaming = true
        detailError = nil
        defer { isRenaming = false }
        do {
            audio = try await service.renameAudioItem(itemId, name: nextName)
            showRenameSheet = false
            Haptics.success()
        } catch {
            detailError = error.localizedDescription
            Haptics.error()
        }
    }

    private func savePreferences(_ updates: UpdateLibraryPreferencesRequest) async {
        guard !isSavingPreferences else { return }
        isSavingPreferences = true
        detailError = nil
        defer { isSavingPreferences = false }
        do {
            preferences = try await service.updateLibraryPreferences(itemReference, updates: updates)
            Haptics.light()
        } catch {
            detailError = error.localizedDescription
            Haptics.error()
        }
    }

    private func addTag() async {
        let nextTag = tagInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nextTag.isEmpty,
              !preferences.tags.contains(where: { $0.caseInsensitiveCompare(nextTag) == .orderedSame })
        else { return }
        await savePreferences(
            UpdateLibraryPreferencesRequest(tags: preferences.tags + [nextTag])
        )
        if detailError == nil { tagInput = "" }
    }

    private func removeTag(_ tag: String) async {
        await savePreferences(
            UpdateLibraryPreferencesRequest(tags: preferences.tags.filter { $0 != tag })
        )
    }

    private func retryAudioTranscription() async {
        guard isAudioItem else { return }
        guard await aiProcessingConsent.requestPermission() else { return }
        guard !isRetrying else { return }
        isRetrying = true
        detailError = nil
        defer { isRetrying = false }
        do {
            audio = try await service.retryAudioItem(itemId)
            Haptics.light()
            startDetailPolling()
        } catch {
            detailError = error.localizedDescription
            Haptics.error()
        }
    }

    private func formatTranscriptForReadability() async {
        guard await aiProcessingConsent.requestPermission() else { return }
        guard isAudioItem, !isFormattingTranscript else { return }
        isFormattingTranscript = true
        detailError = nil
        defer { isFormattingTranscript = false }
        do {
            audio = try await service.formatAudioTranscript(itemId)
            transcriptViewMode = .readable
            Haptics.light()
            startDetailPolling()
        } catch {
            detailError = error.localizedDescription
            Haptics.error()
        }
    }

    private func startDetailPolling() {
        detailPollingTask?.cancel()
        pollingWarning = nil
        detailPollingTask = Task {
            while !Task.isCancelled,
                  let current = audio,
                  ["pending", "processing"].contains(current.status)
                    || ["pending", "processing"].contains(current.formattingStatus ?? "none") {
                do {
                    try await Task.sleep(for: .seconds(3))
                    audio = try await service.getAudioItem(itemId)
                    pollingWarning = nil
                } catch is CancellationError {
                    return
                } catch {
                    // Keep the last known item visible and try again after the
                    // normal polling delay. A brief connection loss should not
                    // strand the screen in a stale processing state.
                    pollingWarning = "The recording is safe. Retrying the latest status automatically…"
                }
            }
            pollingWarning = nil
            if audio?.status == "completed" { Haptics.success() }
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
        guard await aiProcessingConsent.requestPermission() else { return }
        guard !isLoadingSummary else { return }
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
