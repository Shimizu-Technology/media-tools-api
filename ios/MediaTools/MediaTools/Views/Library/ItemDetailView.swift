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

private enum DetailTab: String, Hashable {
    case summary
    case transcript
}

struct ItemDetailView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: LibraryItem
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
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
    @State private var summaryError: String?
    @State private var transcriptSummaryIsRunning = false
    @State private var showExportSheet = false
    @State private var exportText = ""
    @State private var preferences = LibraryPreferences(favorite: false, archived: false, tags: [])
    @State private var tagInput = ""
    @State private var isSavingPreferences = false
    @State private var showRenameSheet = false
    @State private var renameValue = ""
    @State private var isRenaming = false
    @State private var isRetrying = false
    /// Nil until someone picks: timed lines when the audio has them, otherwise text.
    @State private var transcriptModeChoice: TranscriptViewMode?
    /// Nil until someone picks: the summary when there is one, otherwise the transcript.
    @State private var tabChoice: DetailTab?
    @State private var isFormattingTranscript = false
    @State private var detailError: String?
    @State private var pollingWarning: String?
    @State private var detailPollingTask: Task<Void, Never>?
    @State private var reportTarget: AIContentReportTarget?
    @State private var showTagsSheet = false
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    /// The same player drives the inline control and the bar that takes over when
    /// a timestamp starts playback with the inline control off screen.
    @State private var player = AudioPlayerService()
    @State private var isPlayerVisible = true

    private let service = MediaToolsService.shared

    private static let transcriptSummaryTypes = [
        ("general", "General"),
        ("tutorial", "Tutorial"),
        ("lecture", "Lecture"),
        ("podcast", "Podcast"),
        ("conference", "Conference"),
        ("review", "Review"),
        ("news", "News"),
    ]

    // The audio endpoint rejects anything else. Keep in sync with
    // ValidContentTypes in internal/models/models.go.
    private static let audioSummaryTypes = [
        ("general", "General"),
        ("phone_call", "Conversation"),
        ("meeting", "Meeting"),
        ("voice_memo", "Voice Memo"),
        ("interview", "Interview"),
        ("lecture", "Lecture"),
    ]

    private var summaryTypes: [(String, String)] {
        isAudioItem ? Self.audioSummaryTypes : Self.transcriptSummaryTypes
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    headerSection
                    audioPlayerSection
                    noticesSection
                    contentTabs
                    switch visibleTab {
                    case .summary: summarySection
                    case .transcript: transcriptSection
                    }
                }
                .readingMeasure()
                .pageMargin()
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .onChange(of: scrollTarget) {
                guard let scrollTarget else { return }
                // The target may be on the tab that was only just selected.
                Task { @MainActor in
                    await Task.yield()
                    withMotion {
                        proxy.scrollTo(scrollTarget, anchor: .center)
                    }
                    self.scrollTarget = nil
                }
            }
        }
        .background(Theme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .sheet(isPresented: $showChat) {
            NavigationStack {
                ChatView(itemType: chatItemType, itemId: itemId, onCitationTap: handleCitation)
                    .navigationTitle("Ask")
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
        .sheet(isPresented: $showRenameSheet) {
            renameSheet
        }
        .sheet(isPresented: $showTagsSheet) {
            tagsSheet
        }
        .sheet(item: $reportTarget) { target in
            AIContentReportSheet(target: target)
        }
        .confirmationDialog(
            "Delete This Item?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await deleteItem() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the selected content and cannot be undone.")
        }
        .toolbar { detailToolbar }
        .task { await loadDetail() }
        .onChange(of: audio?.hasDistinctReadableTranscript) { _, hasDistinctOriginal in
            if hasDistinctOriginal != true, transcriptModeChoice == .original {
                transcriptModeChoice = .readable
            }
        }
        .onDisappear { detailPollingTask?.cancel() }
    }

    // MARK: - Toolbar

    /// Sharing and everything else, with the rarer actions in the menu.
    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        // The title sits in the page, where a long name can wrap. It stays set on the
        // bar for Back and VoiceOver, but the actions leave too little room to show it.
        ToolbarItem(placement: .principal) {
            Text(verbatim: "")
                .accessibilityHidden(true)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                exportText = visibleTranscriptText ?? ""
                showExportSheet = true
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(visibleTranscriptText == nil)
            .accessibilityLabel("Export")
        }
        ToolbarItem(placement: .topBarTrailing) {
            moreMenu
        }
    }

    private var moreMenu: some View {
        Menu {
            Section {
                Button {
                    showAddToCollection = true
                } label: {
                    Label("Add to Collection", systemImage: "folder.badge.plus")
                }
                if isAudioItem {
                    Button(action: beginRename) {
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
                    showTagsSheet = true
                } label: {
                    Label("Tags", systemImage: "tag")
                }
                if let text = visibleTranscriptText {
                    Button {
                        UIPasteboard.general.string = text
                        Haptics.success()
                    } label: {
                        Label("Copy Text", systemImage: "doc.on.doc")
                    }
                }
            }

            if canSummarize {
                Section {
                    Picker(selection: $summaryContentType) {
                        ForEach(summaryTypes, id: \.0) { type in
                            Text(type.1).tag(type.0)
                        }
                    } label: {
                        Label("Summary Style", systemImage: "text.alignleft")
                    }
                    .pickerStyle(.menu)

                    Button {
                        Task { await generateSummary() }
                    } label: {
                        Label(
                            summary?.summary == nil ? "Summarize" : "Summarize Again",
                            systemImage: "text.badge.star"
                        )
                    }
                    .disabled(isLoadingSummary || isSummaryRunning)
                }
            }

            Section {
                // App Review expects AI reporting to be findable, not prominent.
                if let summaryID = summary?.id, summary?.summary != nil {
                    Button {
                        reportTarget = AIContentReportTarget(
                            targetType: isAudioItem ? .audioSummary : .transcriptSummary,
                            targetId: summaryID
                        )
                    } label: {
                        Label("Report Summary", systemImage: "flag")
                    }
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
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(isDeleting)
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("More actions")
        .accessibilityIdentifier("detail.more")
    }

    // MARK: - Bottom bar

    /// Floats over the page, so reading continues underneath it.
    @ViewBuilder
    private var bottomBar: some View {
        let showsMiniPlayer = !isPlayerVisible && player.isPlaying
        if canUseContentActions || showsMiniPlayer {
            VStack(spacing: 8) {
                if showsMiniPlayer {
                    AudioMiniBar(player: player, onLocate: locateActiveSegment)
                        .padding(.horizontal, 8)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous))
                        .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
                        .transition(.opacity)
                }
                if canUseContentActions {
                    askBox
                }
            }
            .readingMeasure()
            .pageMargin()
            .padding(.bottom, 8)
            .animation(reduceMotion ? nil : Theme.quick, value: showsMiniPlayer)
        }
    }

    /// Opens the conversation, keyboard up, with any earlier answers above it.
    private var askBox: some View {
        Button {
            Task {
                guard await aiProcessingConsent.requestPermission() else { return }
                showChat = true
            }
        } label: {
            Label("Ask about this", systemImage: "sparkles")
        }
        .buttonStyle(PrimaryButtonStyle(shape: .pill))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .accessibilityLabel("Ask about this")
        .accessibilityIdentifier("detail.ask")
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.displayTitle)
                .tracking(-0.3)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            if let metadataText {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let collection = rowMetadata?.primaryCollection {
                        CollectionDot(colorKey: collection.color)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    }
                    Text(metadataText)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !preferences.tags.isEmpty {
                Text(preferences.tags.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityLabel("Tags: \(preferences.tags.joined(separator: ", "))")
            }
        }
    }

    /// What the list already knows and the detail endpoint does not send.
    private var rowMetadata: LibraryListItem? {
        service.libraryRow(for: itemReference)
    }

    private var metadataText: String? {
        var parts: [String] = []
        if let collection = rowMetadata?.primaryCollection {
            parts.append(collection.name)
        }
        if let date = createdAt {
            let day = MediaFormat.dayTitle(for: date)
            parts.append("\(day), \(date.formatted(date: .omitted, time: .shortened))")
        }
        if audio?.isComplete != true, let duration = audioDuration.flatMap(MediaFormat.duration) {
            parts.append(duration)
        } else if !isAudioItem, let words = wordCount, words > 0 {
            parts.append("\(words) words")
        }
        if let type = RecordingContentType.all.first(where: { $0.value == audio?.contentType }),
           type.value != "general" {
            parts.append(type.title)
        }
        if preferences.archived { parts.append("Archived") }
        if preferences.favorite { parts.append("Starred") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var createdAt: Date? {
        switch item {
        case .transcript(let t): (transcript ?? t).createdAt
        case .audio(let a): (audio ?? a).createdAt
        case .pdf(let p): (pdf ?? p).createdAt
        }
    }

    private var canSummarize: Bool {
        if case .pdf = item { return false }
        return canUseContentActions
    }

    /// True whether Summarize was tapped here or the server started on its own.
    private var isSummaryRunning: Bool {
        if let audio {
            return ["pending", "processing"].contains(audio.summaryStatus ?? "")
        }
        return transcriptSummaryIsRunning
    }

    private var canUseContentActions: Bool {
        !["pending", "processing", "failed"].contains(statusText)
    }

    // MARK: - Status

    /// Shows only what needs attention. A finished item has nothing here.
    @ViewBuilder
    private var noticesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let detailError {
                detailErrorBanner(detailError)
            }
            if let pollingWarning {
                NoticeRow(
                    systemImage: "wifi.exclamationmark",
                    title: "Connection interrupted",
                    message: pollingWarning
                )
            }
            processingSection
            if isSavingPreferences {
                ProgressNote(text: "Saving…")
            }
        }
        .padding(.top, hasNotices ? 16 : 0)
    }

    private var hasNotices: Bool {
        detailError != nil || pollingWarning != nil || isSavingPreferences
            || audio.map { ["pending", "processing", "failed"].contains($0.status) } == true
            || nonAudioFailureMessage != nil || isNonAudioItemProcessing
    }

    @ViewBuilder
    private var processingSection: some View {
        if let audio, ["pending", "processing"].contains(audio.status) {
            VStack(alignment: .leading, spacing: 8) {
                ProgressNote(text: "\(audio.processingDescription). You can leave this screen. Media Tools keeps working in the background.")
                if let progress = audio.processingProgress, progress > 0 {
                    ProgressView(value: Double(progress), total: 100)
                        .accessibilityLabel("Transcription progress")
                        .accessibilityValue("\(progress) percent")
                }
            }
        } else if let message = nonAudioFailureMessage {
            NoticeRow(
                systemImage: "exclamationmark.circle",
                title: "This item needs attention",
                message: message
            )
        } else if isNonAudioItemProcessing {
            ProgressNote(text: "You can leave this screen. Media Tools keeps working in the background.")
        } else if let audio, audio.status == "failed" {
            NoticeRow(
                systemImage: "exclamationmark.circle",
                title: "Transcription needs attention",
                message: audio.errorMessage ?? "The recording could not be transcribed."
            ) {
                if audio.isRetryable {
                    Button {
                        Task { await retryAudioTranscription() }
                    } label: {
                        if isRetrying {
                            ProgressView()
                        } else {
                            Text("Retry Transcription")
                        }
                    }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(isRetrying)
                }
            }
        }
    }

    // MARK: - Tags

    private var tagsSheet: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        TextField("Add a tag", text: $tagInput)
                            .submitLabel(.done)
                            .onSubmit { Task { await addTag() } }
                            .onChange(of: tagInput) { _, value in
                                if value.count > 40 { tagInput = String(value.prefix(40)) }
                            }
                        Button("Add") { Task { await addTag() } }
                            .buttonStyle(QuietButtonStyle())
                            .disabled(
                                tagInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || isSavingPreferences
                            )
                    }
                    .frame(minHeight: 44)
                    .listRowBackground(Theme.surface)
                }
                if !preferences.tags.isEmpty {
                    Section {
                        ForEach(preferences.tags, id: \.self) { tag in
                            HStack {
                                Text(tag)
                                    .foregroundStyle(Theme.text)
                                Spacer()
                                Button {
                                    Task { await removeTag(tag) }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.footnote)
                                        .foregroundStyle(Theme.textSecondary)
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(isSavingPreferences)
                                .accessibilityLabel("Remove \(tag) tag")
                            }
                            .listRowBackground(Theme.surface)
                        }
                    }
                }
                if let detailError {
                    Section {
                        InlineError(detailError)
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .themedListBackground()
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showTagsSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Audio Player

    /// The detail's 200 peaks when the server has them, else the row's 32. Without
    /// either the player keeps a plain track, because it must not draw invented bars.
    private var playerWaveform: [Int]? {
        if let peaks = audio?.waveform, WaveformDisplay.hasData(peaks) { return peaks }
        if let peaks = rowMetadata?.waveform, WaveformDisplay.hasData(peaks) { return peaks }
        return nil
    }

    @ViewBuilder
    private var audioPlayerSection: some View {
        if let audio, audio.isComplete {
            AudioPlayerView(
                player: player,
                audioId: audio.id,
                knownDuration: audio.duration,
                waveform: playerWaveform,
                seekTime: $audioSeekTime
            )
            .padding(.top, 14)
            .onScrollVisibilityChange(threshold: 0.2) { isPlayerVisible = $0 }
        }
    }

    // MARK: - Summary

    private var summaryFailureMessage: String? {
        if let summaryError { return summaryError }
        if let audio, audio.summaryStatus == "failed" {
            return audio.summaryErrorMessage ?? "The summary could not be generated."
        }
        if let summary, summary.isFailed { return summary.failureMessage }
        return nil
    }

    private var hasSummarySection: Bool {
        summary?.summary != nil || isSummaryRunning || isLoadingSummary
            || summaryFailureMessage != nil || canSummarize
    }

    private var hasTranscript: Bool {
        contentText?.isEmpty == false
    }

    private var visibleTab: DetailTab {
        if let tabChoice {
            if tabChoice == .summary, !hasSummarySection { return .transcript }
            if tabChoice == .transcript, !hasTranscript { return .summary }
            return tabChoice
        }
        let summaryIsWorthOpening = summary?.summary != nil || isSummaryRunning
            || isLoadingSummary || summaryFailureMessage != nil
        return summaryIsWorthOpening || !hasTranscript ? .summary : .transcript
    }

    /// Only when there is a real choice. A PDF has its text and nothing to switch to.
    @ViewBuilder
    private var contentTabs: some View {
        if hasSummarySection, hasTranscript {
            HStack(spacing: 0) {
                tabButton("Summary", tab: .summary)
                tabButton(pdf == nil ? "Transcript" : "Text", tab: .transcript)
            }
            .padding(3)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.radiusMedium, style: .continuous))
            .padding(.top, 14)
        }
    }

    private func tabButton(_ title: String, tab: DetailTab) -> some View {
        let isSelected = visibleTab == tab
        return Button {
            withMotion(Theme.quick) { tabChoice = tab }
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? Theme.text : Theme.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Theme.surface)
                            .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("detail.tab.\(tab.rawValue)")
    }

    /// The reason most people opened this item.
    @ViewBuilder
    private var summarySection: some View {
        let summaryText = summary?.summary
        let isWorking = isSummaryRunning || isLoadingSummary
        if hasSummarySection {
            VStack(alignment: .leading, spacing: 6) {
                if isWorking {
                    ProgressNote(text: "Summarizing…")
                } else if let summaryFailureMessage {
                    NoticeRow(
                        systemImage: "exclamationmark.circle",
                        title: "Summary needs attention",
                        message: summaryFailureMessage
                    ) {
                        if canSummarize { summarizeButton(title: "Try Again") }
                    }
                }

                if let summary, let summaryText {
                    summaryBody(summary, text: summaryText)
                } else if !isWorking, summaryFailureMessage == nil {
                    summarizeButton(title: "Summarize")
                }
            }
            .padding(.top, 16)
        }
    }

    private func summarizeButton(title: String) -> some View {
        Button(title) {
            Task { await generateSummary() }
        }
        .buttonStyle(QuietButtonStyle())
        .accessibilityIdentifier("detail.summarize")
    }

    private func summaryBody(_ summary: Summary, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .readingText()
                .textSelection(.enabled)

            CitationChips(
                citations: summary.evidence?.summary ?? [],
                onTap: handleCitation
            )

            if let points = summary.keyPoints, !points.isEmpty {
                summaryListHeading("Key Points")
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    summaryListItem(
                        point,
                        citations: summary.evidence?.keyPoints?[safe: index] ?? []
                    )
                }
            }

            if let actions = summary.actionItems, !actions.isEmpty {
                summaryListHeading("Action Items")
                ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                    summaryListItem(
                        action,
                        citations: summary.evidence?.actionItems?[safe: index] ?? []
                    )
                }
            }

            if let topics = summary.topics, !topics.isEmpty {
                summaryListHeading("Topics")
                Text(topics.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func summaryListHeading(_ title: String) -> some View {
        SectionLabel(title)
            .padding(.top, 12)
    }

    private func summaryListItem(_ text: String, citations: [Citation]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accentText)
                    .accessibilityHidden(true)
                Text(text)
                    .readingText()
                    .textSelection(.enabled)
            }
            CitationChips(citations: citations, onTap: handleCitation)
        }
    }

    // MARK: - Transcript Text

    @ViewBuilder
    private var transcriptSection: some View {
        if let text = contentText, !text.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if isAudioItem {
                    HStack(alignment: .firstTextBaseline) {
                        if transcriptViewMode != .readable || audio?.hasDistinctReadableTranscript == true {
                            Text(transcriptViewDescription)
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        if availableTranscriptViewModes.count > 1 {
                            transcriptModeMenu
                        }
                    }
                    if transcriptViewMode == .readable {
                        transcriptFormattingState
                    }
                }

                if isAudioItem && transcriptViewMode == .timestamps && !segments.isEmpty {
                    timestampedTranscript
                } else if !isAudioItem && !segments.isEmpty {
                    timestampedTranscript
                } else {
                    ReadingBody(text: visibleTranscriptText ?? text)
                }
            }
            .padding(.top, 12)
        }
    }

    private var transcriptModeMenu: some View {
        Menu {
            Picker("Transcript view", selection: Binding(
                get: { transcriptViewMode },
                set: { transcriptModeChoice = $0 }
            )) {
                ForEach(availableTranscriptViewModes) { mode in
                    Text(mode.title).tag(mode)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(transcriptViewMode.rawValue)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .accessibilityHidden(true)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.accentText)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Transcript view")
        .accessibilityValue(transcriptViewMode.rawValue)
        .accessibilityIdentifier("detail.transcript-mode")
    }

    /// Tapping a timestamp plays that moment and leaves the page where it is.
    private var timestampedTranscript: some View {
        TimedTranscript(player: player, segments: segments, onSelect: handleSegment)
    }

    /// Timed lines when the audio has them, the mockup's transcript, until someone picks.
    private var transcriptViewMode: TranscriptViewMode {
        if let transcriptModeChoice { return transcriptModeChoice }
        return hasTimedSegments ? .timestamps : .readable
    }

    private var hasTimedSegments: Bool {
        segments.contains { $0.startMs != nil }
    }

    /// Back to the line now playing, from anywhere in a long transcript.
    private var locateActiveSegment: (() -> Void)? {
        guard isAudioItem, hasTimedSegments else { return nil }
        return {
            tabChoice = .transcript
            transcriptModeChoice = .timestamps
            if let index = segments.activeSegmentIndex(at: player.currentTime) {
                scrollTarget = segments[index].id
            }
        }
    }

    @ViewBuilder
    private var transcriptFormattingState: some View {
        if let audio {
            switch audio.formattingStatus ?? "none" {
            case "pending", "processing":
                ProgressNote(text: "Formatting for readability… Your transcript is available now.")
            case "failed":
                NoticeRow(
                    systemImage: "exclamationmark.circle",
                    title: "Readable formatting could not finish",
                    message: audio.formattingErrorMessage ?? "Your transcript is shown unchanged."
                ) {
                    Button {
                        Task { await formatTranscriptForReadability() }
                    } label: {
                        if isFormattingTranscript { ProgressView() } else { Text("Try Again") }
                    }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(isFormattingTranscript)
                }
            case "none":
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("This recording predates readable formatting.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                    Button {
                        Task { await formatTranscriptForReadability() }
                    } label: {
                        if isFormattingTranscript { ProgressView() } else { Text("Improve") }
                    }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(isFormattingTranscript)
                    .accessibilityLabel("Improve readability")
                }
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
            "Tap a line to play that moment."
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
        case .transcript(let t): (transcript ?? t).displayTitle
        case .audio(let a): (audio ?? a).displayTitle
        case .pdf(let p): (pdf ?? p).displayTitle
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

    private var statusText: String {
        switch item {
        case .transcript(let t): (transcript ?? t).status
        case .audio(let a): (audio ?? a).status
        case .pdf(let p): (pdf ?? p).status
        }
    }

    private var wordCount: Int? {
        switch item {
        case .transcript(let t): (transcript ?? t).wordCount
        case .audio(let a): (audio ?? a).wordCount
        case .pdf(let p): (pdf ?? p).wordCount
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

    /// What copying and exporting hand over. Stamped lines only when someone chose
    /// them: a plain export stays plain even though timed lines show by default.
    private var visibleTranscriptText: String? {
        guard let audio else { return contentText }
        switch transcriptModeChoice ?? .readable {
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

    private var nonAudioFailureMessage: String? {
        if let transcript, transcript.status == "failed" {
            return transcript.errorMessage ?? "This video could not be transcribed."
        }
        if let pdf, pdf.status == "failed" {
            return pdf.errorMessage ?? "This PDF could not be processed."
        }
        return nil
    }

    private var isNonAudioItemProcessing: Bool {
        let status = transcript?.status ?? pdf?.status ?? ""
        return ["pending", "processing"].contains(status)
    }

    private var needsDetailPolling: Bool {
        if let audio {
            return ["pending", "processing"].contains(audio.status)
                || ["pending", "processing"].contains(audio.formattingStatus ?? "none")
                || isSummaryRunning
        }
        return isNonAudioItemProcessing || isSummaryRunning
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
                await loadTranscriptSummary()
            case .audio(let a):
                let loaded = try await service.getAudioItem(a.id)
                if Self.audioSummaryTypes.contains(where: { $0.0 == loaded.contentType }) {
                    summaryContentType = loaded.contentType ?? summaryContentType
                }
                applyAudio(loaded)
            case .pdf(let p):
                pdf = try await service.getPDF(p.id)
            }
            if needsDetailPolling {
                startDetailPolling()
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

        await loadSegments()
    }

    private func loadSegments() async {
        do {
            segments = try await service.getMediaSegments(itemType: chatItemType, itemId: itemId)
        } catch {
            // Legacy items may predate source segments; plain text remains usable.
            print("Failed to load source segments: \(error)")
        }
    }

    /// A server response is the source of truth for the summary, which may have
    /// been started by the server rather than by this screen.
    private func applyAudio(_ updated: AudioTranscription) {
        audio = updated
        if updated.summaryStatus == "completed" {
            summary = service.audioSummary(from: updated)
            summaryError = nil
        }
    }

    private func loadTranscriptSummary() async {
        guard let summaries = try? await service.getSummaries(transcriptId: itemId),
              let latest = summaries.first
        else {
            transcriptSummaryIsRunning = false
            return
        }
        let hasText = latest.summaryText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        transcriptSummaryIsRunning = !hasText && !latest.isFailed
        if hasText || latest.isFailed {
            summary = latest
        }
    }

    private func detailErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            InlineError(message)
            Button {
                detailError = nil
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

    private var renameSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Recording title", text: $renameValue)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                        .onSubmit { Task { await renameAudio() } }
                        .accessibilityIdentifier("recording.rename.field")
                        .listRowBackground(Theme.surface)
                } footer: {
                    Text("Use a name you will recognize in search, exports, and collections.")
                        .foregroundStyle(Theme.textSecondary)
                }

                if let detailError {
                    Section {
                        InlineError(detailError)
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .themedListBackground()
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
        .presentationDetents([.medium, .large])
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
            applyAudio(try await service.renameAudioItem(itemId, name: nextName))
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
            applyAudio(try await service.retryAudioItem(itemId))
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
            applyAudio(try await service.formatAudioTranscript(itemId))
            transcriptModeChoice = .readable
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
            let wasProcessing = !["completed", "failed"].contains(statusText)
            while !Task.isCancelled, needsDetailPolling {
                do {
                    try await Task.sleep(for: .seconds(3))
                    switch item {
                    case .audio:
                        applyAudio(try await service.getAudioItem(itemId))
                    case .transcript:
                        transcript = try await service.getTranscript(itemId)
                        await loadTranscriptSummary()
                    case .pdf:
                        pdf = try await service.getPDF(itemId)
                    }
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
            guard !Task.isCancelled, wasProcessing, statusText == "completed" else { return }
            // Segments are only written once the transcript exists, so the load
            // made when this screen opened came back empty.
            await loadSegments()
            Haptics.success()
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
            // Plays from here without moving the page, so reading carries on where
            // it was. The bottom bar offers pause if the player is out of view.
            audioSeekTime = TimeInterval(startMS) / 1_000
            showChat = false
            return
        }

        // A page reference or an untimed passage lives in the text tab.
        tabChoice = .transcript
        scrollTarget = citation.segmentId
        showChat = false
    }

    private func deleteItem() async {
        isDeleting = true
        detailError = nil
        defer { isDeleting = false }
        do {
            try await service.deleteLibraryItem(itemReference)
            SpotlightService.removeLibraryItems([itemReference])
            Haptics.success()
            dismiss()
        } catch {
            detailError = error.localizedDescription
            Haptics.error()
        }
    }

    private func generateSummary() async {
        guard await aiProcessingConsent.requestPermission() else { return }
        guard !isLoadingSummary else { return }
        isLoadingSummary = true
        summaryError = nil
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
                audio = service.audioItems.first { $0.id == itemId } ?? audio
            case .pdf:
                throw APIError.httpError(statusCode: 400, message: "PDF summaries are not available yet")
            }
            withMotion {
                summary = result
            }
            Haptics.success()
        } catch {
            summaryError = error.localizedDescription
            Haptics.error()
        }
    }
}

// MARK: - Timed transcript

/// Each line can be tapped to play it, and the one playing is highlighted. This is a
/// view of its own so that playback ticks redraw it alone, not the whole detail page.
private struct TimedTranscript: View {
    let player: AudioPlayerService
    let segments: [MediaSegment]
    let onSelect: (MediaSegment) -> Void

    var body: some View {
        // Before anything has played there is nothing to follow.
        let active = player.hasPlaybackPosition ? segments.activeSegmentIndex(at: player.currentTime) : nil
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                TimedTranscriptLine(segment: segment, isActive: index == active) {
                    onSelect(segment)
                }
                .id(segment.id)
            }
        }
        .padding(.horizontal, -8)
    }
}

private struct TimedTranscriptLine: View, Equatable {
    let segment: MediaSegment
    let isActive: Bool
    let action: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.segment.id == rhs.segment.id && lhs.isActive == rhs.isActive
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(segment.locatorLabel)
                    .font(.number)
                    .foregroundStyle(segment.startMs == nil ? Theme.textSecondary : Theme.accentText)
                Text(segment.text)
                    .readingText()
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                isActive ? Theme.surface2 : .clear,
                in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityHint(segment.startMs == nil ? "" : "Plays from this moment")
        .accessibilityValue(isActive ? "Now playing" : "")
    }
}

// MARK: - Evidence Links

struct CitationChips: View {
    let citations: [Citation]
    let onTap: (Citation) -> Void

    var body: some View {
        if !citations.isEmpty {
            FlowLayout(spacing: 12) {
                ForEach(citations, id: \.self) { citation in
                    Button {
                        onTap(citation)
                    } label: {
                        Label(citation.locatorLabel, systemImage: citation.pageNumber == nil ? "play.fill" : "doc.text")
                            .font(.footnote.monospacedDigit())
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(Theme.accentText)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open source at \(citation.locatorLabel)")
                }
            }
        }
    }
}

/// Long transcripts render a paragraph at a time, so scrolling stays smooth and a
/// very tall block of text never has to be laid out in one piece.
struct ReadingBody: View {
    let text: String

    private var paragraphs: [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .readingText()
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
    @State private var files: [ExportFile] = []
    @State private var exportError: String?

    private struct ExportFile: Identifiable {
        let label: String
        let icon: String
        let url: URL
        var id: String { label }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // ShareLink presents from this sheet. Presenting from the root
                    // view controller failed silently, because that controller was
                    // already busy presenting this sheet.
                    ForEach(files) { file in
                        ShareLink(item: file.url) {
                            Label(file.label, systemImage: file.icon)
                                .foregroundStyle(Theme.text)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .listRowBackground(Theme.surface)
                    }
                }

                if let exportError {
                    Section {
                        InlineError(exportError)
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .themedListBackground()
            .navigationTitle("Export As")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { prepareFiles() }
    }

    private func prepareFiles() {
        guard files.isEmpty else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        // A title can contain "/" or ":", which would otherwise fail the write
        // and leave nothing to share.
        let safeTitle = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
        let jsonData = try? JSONSerialization.data(
            withJSONObject: ["title": title, "text": text],
            options: .prettyPrinted
        )
        let formats: [(String, String, String, Data?)] = [
            ("Plain Text (.txt)", "doc.text", "txt", Data(text.utf8)),
            ("Markdown (.md)", "doc.richtext", "md", Data("# \(title)\n\n\(text)".utf8)),
            ("JSON (.json)", "curlybraces", "json", jsonData),
        ]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            files = try formats.compactMap { label, icon, fileExtension, data in
                guard let data else { return nil }
                let url = directory.appendingPathComponent("\(safeTitle).\(fileExtension)")
                try data.write(to: url, options: .atomic)
                return ExportFile(label: label, icon: icon, url: url)
            }
        } catch {
            exportError = "The export could not be prepared: \(error.localizedDescription)"
        }
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
