import SwiftUI
import UniformTypeIdentifiers

/// The content types the audio endpoint accepts. Keep in sync with
/// ValidContentTypes in internal/models/models.go.
struct RecordingContentType: Identifiable, Hashable {
    let value: String
    let title: String
    let systemImage: String

    var id: String { value }

    static let all = [
        RecordingContentType(value: "general", title: "General", systemImage: "waveform"),
        RecordingContentType(value: "phone_call", title: "Conversation", systemImage: "person.2.wave.2"),
        RecordingContentType(value: "meeting", title: "Meeting", systemImage: "person.3"),
        RecordingContentType(value: "voice_memo", title: "Voice Memo", systemImage: "bubble.left"),
        RecordingContentType(value: "interview", title: "Interview", systemImage: "doc.text"),
        RecordingContentType(value: "lecture", title: "Lecture", systemImage: "graduationcap"),
    ]
}

/// The whole recorder. While audio is being captured it is the full gradient screen;
/// before and after, it is a plain page with the result and anything still saved here.
struct RecordView: View {
    /// The in-app default. Most recordings never need another type.
    static let defaultContentType = "general"

    @Environment(RecordingCoordinator.self) private var recorder
    @Environment(RecordingUploadCoordinator.self) private var uploader
    @Environment(AIProcessingConsentManager.self) private var aiProcessingConsent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentType = RecordView.defaultContentType
    @State private var isUploading = false
    @State private var uploadResult: AudioTranscription?
    @State private var pollingTask: Task<Void, Never>?
    @State private var error: String?
    @State private var recordingToDiscard: LocalRecording?
    @State private var showFilePicker = false
    @State private var sharedItemToRemove: ShareInboxStore.Item?
    @State private var startedAt: Date?
    /// Sized from a text style so the clock grows with Dynamic Type, and the line
    /// shrinks it back down rather than wrapping once it runs out of room.
    @ScaledMetric(relativeTo: .largeTitle) private var timerSize: CGFloat = 76
    private let onClose: (() -> Void)?
    private let onOpenItem: ((LibraryReference) -> Void)?

    private let service = MediaToolsService.shared

    init(onClose: (() -> Void)? = nil, onOpenItem: ((LibraryReference) -> Void)? = nil) {
        self.onClose = onClose
        self.onOpenItem = onOpenItem
    }

    /// Starting counts, so a press lands on the gradient straight away, even while
    /// the microphone comes up or iOS asks for permission.
    private var showsActiveCapture: Bool {
        recorder.isRecording || recorder.isStarting
    }

    var body: some View {
        Group {
            if showsActiveCapture {
                activeCapture
            } else {
                idleCapture
            }
        }
        // White text and status bar on the gradient, in light mode too.
        .preferredColorScheme(showsActiveCapture ? .dark : nil)
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: uploader.latestItemSignature) { _, _ in
            withMotion {
                uploadResult = uploader.latestItem
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.audio, .mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    let accessed = url.startAccessingSecurityScopedResource()
                    Task {
                        defer {
                            if accessed { url.stopAccessingSecurityScopedResource() }
                        }
                        await queueImportedRecording(url: url, contentType: contentType)
                    }
                }
            case .failure(let error):
                self.error = error.localizedDescription
            }
        }
        .task {
            uploader.resumePendingWork()
            uploadResult = uploader.latestItem ?? uploadResult
        }
        .onAppear {
            // Arriving from the Action Button or the Live Activity, the capture
            // began before this screen existed.
            if recorder.isRecording, startedAt == nil {
                startedAt = Date().addingTimeInterval(-recorder.duration)
            }
        }
        .onDisappear {
            pollingTask?.cancel()
        }
        .onChange(of: recorder.captureState) { previousState, captureState in
            if previousState == .idle { startedAt = Date() }
            let announcement: String
            switch (previousState, captureState) {
            case (.idle, .recording):
                announcement = "Recording started"
            case (.recording, .paused):
                announcement = "Recording paused"
            case (.paused, .recording):
                announcement = "Recording resumed"
            case (_, .interrupted):
                announcement = "Recording interrupted by another audio source"
            case (_, .idle):
                announcement = recorder.statusMessage ?? "Recording stopped"
            default:
                return
            }
            UIAccessibility.post(
                notification: .announcement,
                argument: announcement
            )
        }
        .alert(
            "Remove this share?",
            isPresented: Binding(
                get: { sharedItemToRemove != nil },
                set: { if !$0 { sharedItemToRemove = nil } }
            ),
            presenting: sharedItemToRemove
        ) { item in
            Button("Remove", role: .destructive) {
                uploader.discardSharedItem(item)
                sharedItemToRemove = nil
            }
            Button("Keep", role: .cancel) {
                sharedItemToRemove = nil
            }
        } message: { _ in
            Text("This removes the copy saved on this iPhone and cannot be undone.")
        }
        .alert(
            "Discard recording?",
            isPresented: Binding(
                get: { recordingToDiscard != nil },
                set: { if !$0 { recordingToDiscard = nil } }
            ),
            presenting: recordingToDiscard
        ) { recording in
            Button("Discard", role: .destructive) {
                withMotion {
                    uploader.discard(recording)
                }
                recordingToDiscard = nil
            }
            Button("Keep Recording", role: .cancel) {
                recordingToDiscard = nil
            }
        } message: { _ in
            Text("This removes the audio from this iPhone and cannot be undone.")
        }
    }

    // MARK: - While recording

    private var activeCapture: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    activeTopRow

                    timer
                        .padding(.top, 20)

                    Text("New recording")
                        .font(.displayTitle3)
                        .multilineTextAlignment(.center)
                        .padding(.top, 12)

                    if let startedAtText {
                        Text(startedAtText)
                            .font(.subheadline.weight(.medium))
                            .multilineTextAlignment(.center)
                            .padding(.top, 2)
                    }

                    LiveLevelBars(levels: recorder.levelMeter.levels)
                        .frame(height: 112)
                        .frame(maxWidth: 420)
                        .padding(.top, 28)
                        .opacity(recorder.captureState == .recording ? 1 : 0.55)

                    Spacer(minLength: 28)

                    captureControls
                        .opacity(recorder.isRecording ? 1 : 0)
                        .allowsHitTesting(recorder.isRecording)
                        .accessibilityHidden(!recorder.isRecording)

                    Text(captureHint)
                        .font(.footnote.weight(.medium))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 18)
                        .padding(.bottom, 12)
                }
                .foregroundStyle(Theme.onHero)
                .padding(.horizontal, 24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Theme.heroGradient.ignoresSafeArea())
    }

    /// The status, centered, with a way back to reading on the left.
    private var activeTopRow: some View {
        ZStack {
            statusLine
            HStack {
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "chevron.down")
                            .font(.body.weight(.semibold))
                            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressFeedbackButtonStyle())
                    .accessibilityLabel("Keep recording and go back")
                    .accessibilityIdentifier("recording.minimize")
                }
                Spacer()
            }
            .padding(.leading, -12)
        }
        .frame(minHeight: 44)
        .padding(.top, 4)
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            switch recorder.captureState {
            case .recording:
                RecordingPulseDot(size: 10)
                Text("Recording")
            case .paused:
                Image(systemName: "pause.fill")
                    .accessibilityHidden(true)
                Text("Paused")
            case .interrupted:
                Image(systemName: "exclamationmark.circle")
                    .accessibilityHidden(true)
                Text("Interrupted")
            case .idle:
                ProgressView()
                    .tint(Theme.onHero)
                Text("Preparing microphone")
            }
        }
        .font(.subheadline.weight(.semibold))
    }

    private var timer: some View {
        Text(recorder.formattedDuration)
            .font(.system(size: timerSize, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .accessibilityIdentifier("recording.timer")
    }

    private var startedAtText: String? {
        let start = startedAt ?? (recorder.isStarting ? Date() : nil)
        guard let start else { return nil }
        let day = start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        return "\(day), \(start.formatted(date: .omitted, time: .shortened))"
    }

    private var captureControls: some View {
        HStack(alignment: .center, spacing: 36) {
            if !recorder.isInterrupted {
                Button {
                    if recorder.isPaused {
                        if recorder.resume() { Haptics.medium() } else { Haptics.error() }
                    } else {
                        recorder.pause()
                        Haptics.medium()
                    }
                } label: {
                    Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                        .font(.title2)
                        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                        .foregroundStyle(Theme.onHero)
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .frame(width: 76, height: 76)
                        .background(Theme.onHero.opacity(0.22), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(PressFeedbackButtonStyle())
                .accessibilityLabel(recorder.isPaused ? "Resume recording" : "Pause recording")
                .accessibilityHint(
                    recorder.isPaused
                        ? "Continues adding audio to this recording"
                        : "Temporarily stops adding audio without saving yet"
                )
            }

            Button {
                recorder.stop()
                Haptics.medium()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.largeTitle)
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                    .foregroundStyle(Theme.heroIcon)
                    .frame(width: 92, height: 92)
                    .background(Theme.onHero, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(PressFeedbackButtonStyle())
            .accessibilityLabel("Stop and save recording")
            .accessibilityHint("Ends capture and saves the recording on this iPhone")
        }
    }

    private var captureHint: String {
        if recorder.isStarting { return "Your recording starts as soon as the microphone is ready." }
        if recorder.isInterrupted {
            return "Another audio source paused capture. It will resume when iOS allows, or you can stop and save now."
        }
        if recorder.isPaused { return "No audio is being added. Resume when you’re ready, or stop and save." }
        return UIDevice.current.userInterfaceIdiom == .phone
            ? "Press the Action Button again to stop."
            : "Tap stop to save."
    }

    // MARK: - Ready

    private var idleCapture: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                            .foregroundStyle(Theme.accentText)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressFeedbackButtonStyle())
                    .padding(.leading, -12)
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("record.close")
                }

                uploadResultSection
                    .padding(.bottom, uploadResult == nil ? 0 : 20)

                Text(captureTitle)
                    .font(.displayTitle)
                    .tracking(-0.3)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                Text(captureDetail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)

                captureActionButton
                    .padding(.top, 18)

                secondaryCaptureOptions
                    .padding(.top, 6)

                workBelowCapture
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.background)
    }

    private var captureActionButton: some View {
        Button {
            error = nil
            recorder.start(contentType: contentType)
            Haptics.medium()
        } label: {
            Label("Record", systemImage: "mic.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.onHero)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Theme.heroGradient, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressFeedbackButtonStyle(pressedScale: 0.97))
        .disabled(isUploading || recorder.isStarting)
        .accessibilityLabel("Start recording")
        .accessibilityHint("Begins recording from the microphone")
        .accessibilityValue("Not recording")
    }

    /// The default is what almost everyone wants, so choosing a type stays secondary.
    private var secondaryCaptureOptions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                contentTypeMenu
                uploadButton
            }
            VStack(alignment: .leading, spacing: 0) {
                contentTypeMenu
                uploadButton
            }
        }
    }

    private var contentTypeMenu: some View {
        Menu {
            Picker("Recording type", selection: $contentType) {
                ForEach(RecordingContentType.all) { type in
                    Label(type.title, systemImage: type.systemImage).tag(type.value)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text("Type: \(contentTypeTitle)")
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .accessibilityHidden(true)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.accentText)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Recording type")
        .accessibilityValue(contentTypeTitle)
        .accessibilityIdentifier("record.content-type")
    }

    private var contentTypeTitle: String {
        RecordingContentType.all.first { $0.value == contentType }?.title ?? "General"
    }

    private var uploadButton: some View {
        Button("Upload audio file") {
            showFilePicker = true
        }
        .buttonStyle(QuietButtonStyle())
        .disabled(isUploading || recorder.isRecording || recorder.isStarting)
    }

    // MARK: - Results and the saved queue

    private var workBelowCapture: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let visibleError = error ?? recorder.errorMessage {
                VStack(alignment: .leading, spacing: 0) {
                    InlineError(visibleError)
                    if recorder.permissionDenied,
                       let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                        Link("Open Settings", destination: settingsURL)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accentText)
                            .frame(minHeight: 44)
                    }
                }
            }

            // Device-local recovery queue. These files remain available
            // across relaunches until the server has accepted them.
            if !recorder.availableRecordings.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    savedSectionLabel("Saved on this iPhone")
                    ForEach(recorder.availableRecordings) { recording in
                        localRecordingRow(recording)
                        Hairline()
                    }
                }
            }

            if !uploader.sharesNeedingAttention.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    savedSectionLabel("Shares needing attention")
                    Text("These are still saved on this iPhone. Send them, or remove them if you no longer need them.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 6)
                    ForEach(uploader.sharesNeedingAttention) { item in
                        sharedItemRow(item)
                        Hairline()
                    }
                }
            }
        }
        .padding(.top, 20)
        .padding(.bottom, 32)
    }

    private func savedSectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.sectionLabel)
            .foregroundStyle(Theme.textSecondary)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    /// Upload result / polling status
    @ViewBuilder
    private var uploadResultSection: some View {
        if let result = uploadResult {
            VStack(alignment: .leading, spacing: 8) {
                if result.status == "completed" {
                    Text("Transcription complete!")
                        .font(.displayHeadline)
                        .foregroundStyle(Theme.text)

                    if result.wordCount ?? 0 > 0 {
                        Text("\(result.wordCount ?? 0) words  ·  \(formatDuration(result.duration ?? 0))")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }

                    if let text = result.readableTranscriptText, !text.isEmpty {
                        Text(text)
                            .readingText()
                            .lineLimit(3)
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) {
                            viewDetailsLink(for: result)
                            recordAnotherButton
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            viewDetailsLink(for: result)
                            recordAnotherButton
                        }
                    }
                } else if result.status == "failed" {
                    NoticeRow(
                        systemImage: "exclamationmark.circle",
                        title: "Transcription failed",
                        message: result.errorMessage?.isEmpty == false ? result.errorMessage : nil
                    )
                    HStack(spacing: 16) {
                        if result.isRetryable {
                            Button {
                                Task { await retryTranscription(id: result.id) }
                            } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(QuietButtonStyle())
                            .disabled(isUploading)
                        }

                        Button("Start Over") {
                            withMotion {
                                self.uploadResult = nil
                            }
                        }
                        .buttonStyle(QuietButtonStyle(color: Theme.textSecondary))
                    }
                } else {
                    ProgressNote(text: result.processingDescription)
                    if let progress = result.processingProgress, progress > 0 {
                        ProgressView(value: Double(progress), total: 100)
                            .accessibilityLabel("Transcription progress")
                            .accessibilityValue("\(progress) percent")
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous))
        }
    }

    @ViewBuilder
    private func viewDetailsLink(for result: AudioTranscription) -> some View {
        if let onOpenItem {
            Button("View Details") {
                onOpenItem(LibraryReference(itemType: "audio", itemId: result.id))
            }
            .buttonStyle(QuietButtonStyle())
        }
    }

    private var recordAnotherButton: some View {
        Button("Record Another") {
            withMotion {
                self.uploadResult = nil
            }
        }
        .buttonStyle(QuietButtonStyle(color: Theme.textSecondary))
    }

    private func sharedItemRow(_ item: ShareInboxStore.Item) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.originalName)
                .font(.rowTitle)
                .foregroundStyle(Theme.text)
                .lineLimit(2)
            Text(uploader.shareStatusMessage(for: item))
                .font(.footnote)
                .foregroundStyle(
                    recorder.pendingSharedErrors[item.id] == nil
                        ? Theme.textSecondary
                        : Theme.text
                )
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Button(uploader.shareActionTitle(for: item)) {
                    Task { await uploader.retrySharedItem(item) }
                }
                .buttonStyle(QuietButtonStyle())

                Button("Remove", role: .destructive) { sharedItemToRemove = item }
                    .buttonStyle(QuietButtonStyle(color: Theme.danger))

                if let fileURL = recorder.sharedFileURL(for: item) {
                    ShareLink(item: fileURL) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.subheadline)
                            .foregroundStyle(Theme.accentText)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Export \(item.originalName)")
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var captureTitle: String {
        if recorder.isStarting { return "Preparing microphone" }
        if recorder.statusMessage != nil { return "Ready for another recording" }
        return "Ready to record"
    }

    private var captureDetail: String {
        if recorder.isStarting { return "Setting up a secure on-device audio session." }
        if recorder.storageIsLow { return "Free at least 100 MB before starting a new recording." }
        if recorder.statusMessage != nil {
            return "The previous recording is saved."
        }
        return aiProcessingConsent.isAutoTranscribeEnabled
            ? "Record only with required permission. Audio is saved on this iPhone first, then transcribed automatically."
            : "Record only with required permission. Audio is saved on this iPhone first."
    }

    private func localRecordingRow(_ recording: LocalRecording) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recording.displayTitle)
                .font(.rowTitle)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(recording.formattedDuration)  ·  \(recording.recoveryDescription)")
                .font(.footnote)
                .foregroundStyle(
                    [.invalid, .uploadFailed].contains(recording.state)
                        ? Theme.text : Theme.textSecondary
                )
                .fixedSize(horizontal: false, vertical: true)

            if recording.state == .uploading {
                ProgressView(value: recording.uploadProgress ?? 0)
                    .padding(.vertical, 2)
                    .accessibilityLabel("Upload progress")
                    .accessibilityValue(
                        "\(Int(((recording.uploadProgress ?? 0) * 100).rounded())) percent"
                    )
            }

            if recording.state == .invalid {
                Text("Uploading this file unchanged will still fail. Keep the exported original for a recovery attempt.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("recording.recovery-guidance")
            }

            HStack(spacing: 16) {
                if recording.state == .invalid,
                   let fileURL = recorder.fileURL(for: recording) {
                    ShareLink(item: fileURL) {
                        Label("Export for Recovery", systemImage: "square.and.arrow.up")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accentText)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("recording.save.\(recording.id.uuidString)")
                } else {
                    Button {
                        Task { await queueForAIProcessing(recording) }
                    } label: {
                        if recording.isUploadInProgress {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(uploadButtonTitle(for: recording))
                            }
                        } else {
                            Text(uploadActionTitle(for: recording))
                        }
                    }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(
                        !recording.canUpload
                            || recorder.isStarting
                            || recorder.isRecording
                    )
                    .accessibilityIdentifier("recording.transcribe.\(recording.id.uuidString)")
                }

                Button("Discard") {
                    recordingToDiscard = recording
                }
                .buttonStyle(QuietButtonStyle(color: Theme.danger))
                .disabled(
                    (recording.isUploadInProgress && recording.state != .waitingForUpload)
                        || recorder.isStarting
                        || recorder.isRecording
                )
                .accessibilityIdentifier("recording.discard.\(recording.id.uuidString)")
            }
        }
        .padding(.vertical, 8)
    }

    private func queueImportedRecording(url: URL, contentType: String) async {
        error = nil
        do {
            let recording = try recorder.importRecording(from: url, contentType: contentType)
            await queueForAIProcessing(recording)
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }

    private func retryTranscription(id: String) async {
        guard await aiProcessingConsent.requestPermission() else { return }
        isUploading = true
        defer { isUploading = false }
        error = nil
        do {
            let result = try await service.retryAudioItem(id)
            withMotion {
                uploadResult = result
            }
            Haptics.light()
            startPolling(id: id)
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }

    private func queueForAIProcessing(_ recording: LocalRecording) async {
        guard await aiProcessingConsent.requestPermission(),
              let currentRecording = recorder.recording(withID: recording.id),
              !currentRecording.isUploadInProgress else { return }
        error = nil
        uploader.queue(currentRecording)
        Haptics.light()
    }

    private func startPolling(id: String) {
        pollingTask?.cancel()
        pollingTask = Task {
            var consecutiveFailures = 0

            while !Task.isCancelled,
                let current = uploadResult,
                isResultProcessing(current)
            {
                do {
                    try await Task.sleep(for: .seconds(3))
                    let updated = try await service.getAudioItem(id)
                    consecutiveFailures = 0
                    withMotion {
                        uploadResult = updated
                    }
                } catch is CancellationError {
                    return
                } catch {
                    consecutiveFailures += 1
                    if consecutiveFailures >= 3 {
                        self.error =
                            "The upload is safe, but status could not refresh. Check Library in a moment."
                        break
                    }
                }
            }

            guard !Task.isCancelled else { return }
            await service.loadAudioItems()
            if uploadResult?.status == "completed" {
                Haptics.success()
                NotificationService.notifyAudioComplete(
                    title: uploadResult?.displayTitle ?? "Audio",
                    itemId: id
                )
            } else if uploadResult?.status == "failed" {
                Haptics.error()
            }
        }
    }

    private func isResultProcessing(_ result: AudioTranscription) -> Bool {
        ["pending", "processing"].contains(result.status)
            || ["pending", "processing"].contains(result.formattingStatus ?? "none")
    }

    private func uploadButtonTitle(for recording: LocalRecording) -> String {
        switch recording.state {
        case .waitingForUpload:
            return "Queued"
        case .uploading:
            return "Uploading"
        case .finalizingUpload:
            return "Finishing"
        case .serverProcessing:
            return "Transcribing"
        default:
            return "Transcribe"
        }
    }

    private func uploadActionTitle(for recording: LocalRecording) -> String {
        switch recording.state {
        case .invalid:
            return "Needs Recovery"
        case .uploadFailed:
            return "Retry Upload"
        default:
            return "Transcribe"
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins):\(String(format: "%02d", secs))"
    }
}
