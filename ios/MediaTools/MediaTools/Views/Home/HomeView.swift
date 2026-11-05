import SwiftUI

/// The first thing on screen: record, add something, deal with what needs a person,
/// and pick up what was just captured.
struct HomeView: View {
    let model: HomeViewModel
    let isActive: Bool
    let onRecord: (String) -> Void
    @Environment(AppNavigator.self) private var navigator
    @Environment(RecordingCoordinator.self) private var recorder
    @Environment(RecordingUploadCoordinator.self) private var uploader
    @Environment(AIProcessingConsentManager.self) private var aiProcessingConsent
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var optionsTarget: DeviceItemTarget?
    @State private var width: CGFloat = 0
    @State private var isVisible = false

    /// Wide enough for Recent to sit beside capture, as on iPad.
    private var usesTwoColumns: Bool { width >= 700 }

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, Theme.pageMargin(forWidth: width))
                .padding(.top, 8)
                .padding(.bottom, 32)
                .frame(maxWidth: usesTwoColumns ? 1_040 : nil)
                .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
        .background(Theme.background)
        .navigationTitle("Home")
        .toolbar(.hidden, for: .navigationBar)
        .statusBarBackdrop()
        .refreshable { await model.refresh() }
        .deviceItemActions(target: $optionsTarget)
        .onAppear {
            isVisible = true
            Task { await model.refreshIfStale() }
        }
        .onDisappear { isVisible = false }
        .onChange(of: isActive) { _, active in
            guard active else { return }
            Task { await model.refreshIfStale() }
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
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
                await model.refresh()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if usesTwoColumns {
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 14) {
                    greeting
                    captureSection
                    needsYouSection
                }
                .frame(maxWidth: 420)
                VStack(alignment: .leading, spacing: 14) {
                    recentSection
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                greeting
                captureSection
                needsYouSection
                recentSection
            }
        }
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(HomeGreeting.dateLine())
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(HomeGreeting.text())
                .font(.displayLargeTitle)
                .tracking(-0.4)
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("screen.title")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Capture

    private var captureSection: some View {
        VStack(spacing: 10) {
            RecordCard(onRecord: onRecord, onReturn: { navigator.showRecorder() })
            shortcuts
        }
    }

    private var shortcuts: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            shortcut("Import", systemImage: "waveform", identifier: "home.import") {
                navigator.isImporterPresented = true
            }
            .disabled(recorder.isStarting)
            shortcut("Link", systemImage: "link", identifier: "home.link") {
                navigator.push(.addLink)
            }
            shortcut("PDF", systemImage: "doc.text", identifier: "home.pdf") {
                navigator.push(.addPDF)
            }
        }
    }

    private func shortcut(
        _ title: String,
        systemImage: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(Theme.accentText)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous))
        }
        .buttonStyle(PressFeedbackButtonStyle(pressedScale: 0.97))
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Needs you

    private var needsYouItems: [NeedsYouItem] {
        let willSend = aiProcessingConsent.isAutoTranscribeEnabled && aiProcessingConsent.hasAutomaticConsent
        return NeedsYouSelection.select(
            recordings: recorder.availableRecordings,
            shares: uploader.sharesNeedingAttention,
            serverFailures: model.serverFailures,
            autoTranscribeWillSend: willSend
        )
    }

    @ViewBuilder
    private var needsYouSection: some View {
        let items = needsYouItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Needs you")
                    .padding(.top, 4)
                ForEach(items) { item in
                    NeedsYouRow(
                        item: item,
                        onOptions: { optionsTarget = $0 },
                        onOpen: { navigator.push(.item($0)) }
                    )
                }
            }
        }
    }

    // MARK: - Recent

    /// Audio still on its way sits above what the server lists, as soon as it is saved.
    private var uploadsInProgress: [LocalRecording] {
        let serverIDs = Set(model.recent.map(\.reference))
        return recorder.availableRecordings.filter { recording in
            guard recording.isUploadInProgress else { return false }
            guard let remoteID = recording.remoteTranscriptionID else { return true }
            return !serverIDs.contains(LibraryReference(itemType: "audio", itemId: remoteID))
        }
    }

    private var recentItems: [LibraryListItem] {
        let needing = Set(needsYouItems.map(\.id))
        return model.recent.filter { !needing.contains("server:\($0.reference.id)") }
    }

    @ViewBuilder
    private var recentSection: some View {
        let uploads = uploadsInProgress
        let items = recentItems
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Recent")
                Spacer()
                if !items.isEmpty {
                    Button("See all") { navigator.select(.library) }
                        .buttonStyle(QuietButtonStyle())
                        .accessibilityIdentifier("home.see-all")
                }
            }
            .frame(minHeight: 28)
            ForEach(uploads) { recording in
                RecentUploadCard(recording: recording) {
                    if let remoteID = recording.remoteTranscriptionID {
                        navigator.push(.item(LibraryReference(itemType: "audio", itemId: remoteID)))
                    } else {
                        optionsTarget = .recording(recording.id)
                    }
                }
            }
            ForEach(items, id: \.reference) { item in
                Button {
                    navigator.push(.item(item.reference))
                } label: {
                    RecentCard(item: item)
                }
                .buttonStyle(PressFeedbackButtonStyle(pressedScale: 0.985))
                .accessibilityLabel("Open \(item.displayTitle)")
                .accessibilityIdentifier("home-row-\(item.reference.id)")
            }
            if items.isEmpty, uploads.isEmpty {
                recentPlaceholder
            }
        }
    }

    @ViewBuilder
    private var recentPlaceholder: some View {
        if let loadError = model.loadError {
            QuietPlaceholder(
                systemImage: "wifi.exclamationmark",
                title: "Couldn’t load your recent items",
                message: loadError
            ) {
                Button("Try Again") { Task { await model.refresh() } }
                    .buttonStyle(QuietButtonStyle())
            }
        } else if model.hasLoaded {
            QuietPlaceholder(
                systemImage: "mic",
                title: "Nothing here yet",
                message: "Press Record, or share a voice memo to Media Tools. It will show up here."
            )
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 120)
                .accessibilityLabel("Loading your recent items")
        }
    }
}

// MARK: - Record card

/// The biggest thing on Home. A tap starts the capture; a long press picks a type.
struct RecordCard: View {
    let onRecord: (String) -> Void
    let onReturn: () -> Void
    @Environment(RecordingCoordinator.self) private var recorder
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// A fixed circle, because at the largest text the words need the room instead.
    private let micSize: CGFloat = 64

    /// iPads have no Action Button to mention.
    private var subtitle: String {
        UIDevice.current.userInterfaceIdiom == .phone
            ? "Tap here or press your Action Button"
            : "Tap here to start"
    }

    var body: some View {
        Group {
            if recorder.isRecording {
                Button(action: onReturn) {
                    cardLayout(
                        symbol: "waveform",
                        title: recorder.captureState == .recording ? "Recording" : "Paused",
                        detail: recorder.formattedDuration
                    )
                }
                .accessibilityLabel("Return to recording")
                .accessibilityValue(recorder.formattedDuration)
                .accessibilityIdentifier("home.recording")
            } else {
                Button {
                    onRecord(RecordView.defaultContentType)
                } label: {
                    cardLayout(symbol: "mic.fill", title: "Record", detail: subtitle)
                }
                .disabled(recorder.isStarting)
                .accessibilityLabel("Record")
                .accessibilityHint("Starts recording from the microphone")
                .accessibilityIdentifier("home.record")
                .contextMenu {
                    RecordAsMenu { onRecord($0) }
                }
            }
        }
        .buttonStyle(PressFeedbackButtonStyle(pressedScale: 0.98))
    }

    private func cardLayout(symbol: String, title: String, detail: String) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 14))
        return layout {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Theme.heroIcon)
                .frame(width: micSize, height: micSize)
                .background(Theme.onHero, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.displayTitle2)
                    .tracking(-0.3)
                Text(detail)
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Theme.onHero)
            .multilineTextAlignment(.leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.heroGradient, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

// MARK: - Recent cards

/// A card on Home. Titles and excerpts wrap at accessibility sizes instead of clipping.
struct RecentCard: View {
    let item: LibraryListItem
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.displayTitle)
                    .font(.displayHeadline)
                    .foregroundStyle(Theme.text)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !dynamicTypeSize.isAccessibilitySize, let time = MediaFormat.rowDate(item.createdAt) {
                    Text(time)
                        .font(.footnote)
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
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            RowMetaLine(item: item, showsDate: dynamicTypeSize.isAccessibilitySize, showsLength: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous))
    }
}

/// A recording on its way to the server, on Home.
private struct RecentUploadCard: View {
    let recording: LocalRecording
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(recording.displayTitle)
                        .font(.displayHeadline)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let length = MediaFormat.duration(recording.duration) {
                        Text(length)
                            .font(.number)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize()
                    }
                }
                DeviceProgressLabel(recording: recording)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous))
        }
        .buttonStyle(PressFeedbackButtonStyle(pressedScale: 0.985))
        .accessibilityIdentifier("home-device-\(recording.id.uuidString)")
    }
}
