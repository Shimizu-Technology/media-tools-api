import SwiftUI
import UniformTypeIdentifiers

struct RecordView: View {
    @Environment(RecordingCoordinator.self) private var recorder
    @Environment(RecordingUploadCoordinator.self) private var uploader
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentType = "general"
    @State private var isUploading = false
    @State private var uploadResult: AudioTranscription?
    @State private var pollingTask: Task<Void, Never>?
    @State private var error: String?
    @State private var recordingToDiscard: LocalRecording?
    @State private var showFilePicker = false
    @State private var pulseRing = false

    private let service = MediaToolsService.shared

    private let contentTypes = [
        ("general", "General", "waveform"),
        ("phone_call", "Conversation", "person.2.wave.2"),
        ("meeting", "Meeting", "person.3"),
        ("voice_memo", "Voice Memo", "bubble.left"),
        ("interview", "Interview", "doc.text"),
        ("lecture", "Lecture", "graduationcap"),
    ]

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(spacing: 20) {
                    // Content type selector
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(text: "Content Type", icon: "tag")
                            .padding(.horizontal)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(contentTypes, id: \.0) { type in
                                    Button {
                                        withAnimation(Theme.springSnappy) {
                                            contentType = type.0
                                        }
                                        Haptics.light()
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: type.2)
                                                .font(.caption)
                                            Text(type.1)
                                                .font(.caption)
                                        }
                                        .chipStyle(isSelected: contentType == type.0)
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }

                    captureConsole
                        .padding(.horizontal)

                    // Device-local recovery queue. These files remain available
                    // across relaunches until the server has accepted them.
                    if !recorder.availableRecordings.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(
                                text: "Saved on this iPhone",
                                icon: "iphone.and.arrow.forward"
                            )

                            ForEach(recorder.availableRecordings) { recording in
                                localRecordingCard(recording)
                            }
                        }
                        .padding(.horizontal)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    // Upload result / polling status
                    if let result = uploadResult {
                        VStack(spacing: 8) {
                            if result.status == "completed" {
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Theme.success)
                                    Text("Transcription complete!")
                                        .font(Theme.body(15, weight: .medium))
                                        .foregroundStyle(Theme.textPrimary)
                                }

                                if result.wordCount ?? 0 > 0 {
                                    Text("\(result.wordCount ?? 0) words  ·  \(formatDuration(result.duration ?? 0))")
                                        .font(Theme.caption())
                                        .foregroundStyle(Theme.textSecondary)
                                }

                                if let text = result.readableTranscriptText, !text.isEmpty {
                                    Text(text)
                                        .font(Theme.body(14))
                                        .foregroundStyle(Theme.textSecondary)
                                        .lineLimit(3)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }

                                HStack(spacing: 12) {
                                    NavigationLink(value: LibraryItem.audio(result)) {
                                        Label("View Details", systemImage: "arrow.right.circle.fill")
                                            .font(Theme.body(14, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                            .background(Theme.brand500)
                                            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMedium))
                                    }

                                    Button {
                                        withAnimation(Theme.springSnappy) {
                                            self.uploadResult = nil
                                        }
                                    } label: {
                                        Text("Record Another")
                                            .font(Theme.body(14, weight: .medium))
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                }
                                .padding(.top, 4)
                            } else if result.status == "failed" {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(Theme.error)
                                    Text("Transcription failed")
                                        .font(Theme.body(15, weight: .medium))
                                        .foregroundStyle(Theme.textPrimary)
                                }
                                if let failure = result.errorMessage, !failure.isEmpty {
                                    Text(failure)
                                        .font(Theme.caption())
                                        .foregroundStyle(Theme.textSecondary)
                                        .multilineTextAlignment(.center)
                                }
                                HStack(spacing: 16) {
                                    Button {
                                        Task { await retryTranscription(id: result.id) }
                                    } label: {
                                        Label("Retry", systemImage: "arrow.clockwise")
                                            .font(Theme.body(14, weight: .medium))
                                            .foregroundStyle(Theme.brand500)
                                    }
                                    .disabled(isUploading)
                                    .frame(minHeight: 44)

                                    Button {
                                        withAnimation(Theme.springSnappy) {
                                            self.uploadResult = nil
                                        }
                                    } label: {
                                        Text("Start Over")
                                            .font(Theme.body(14, weight: .medium))
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                    .frame(minHeight: 44)
                                }
                            } else {
                                VStack(spacing: 8) {
                                    HStack(spacing: 8) {
                                        ProgressView()
                                            .tint(Theme.brand400)
                                        Text(result.processingDescription)
                                            .font(Theme.caption())
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                    if let progress = result.processingProgress, progress > 0 {
                                        ProgressView(value: Double(progress), total: 100)
                                            .tint(Theme.brand400)
                                        Text("\(progress)%")
                                            .font(Theme.caption(11))
                                            .foregroundStyle(Theme.textMuted)
                                    }
                                }
                            }
                        }
                        .cardStyle()
                        .padding(.horizontal)
                        .id("upload-result")
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    if let visibleError = error ?? recorder.errorMessage {
                        VStack(spacing: 4) {
                            Text(visibleError)
                                .font(Theme.caption())
                                .foregroundStyle(Theme.error)
                                .multilineTextAlignment(.center)
                            if recorder.permissionDenied,
                                let settingsURL = URL(string: UIApplication.openSettingsURLString)
                            {
                                Link("Open Settings", destination: settingsURL)
                                    .font(Theme.caption(13, weight: .semibold))
                                    .foregroundStyle(Theme.brand400)
                                    .frame(minHeight: 44)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                    }

                    // File upload option
                    Button {
                        showFilePicker = true
                    } label: {
                        Label("Upload Audio File", systemImage: "square.and.arrow.up")
                            .font(Theme.body(14, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(minHeight: 44)
                    .disabled(isUploading || recorder.isRecording || recorder.isStarting)
                    .padding(.bottom, 20)
                    .fileImporter(
                        isPresented: $showFilePicker,
                        allowedContentTypes: [.audio, .mpeg4Movie],
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
                }
                .padding(.top, 12)
            }
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: uploader.latestItemSignature) { _, _ in
                    withAnimation(Theme.springSnappy) {
                        uploadResult = uploader.latestItem
                    }
                    guard uploader.latestItem != nil else { return }
                    Task { @MainActor in
                        // Let SwiftUI commit the result card before resolving its
                        // scroll target. This avoids an occasional no-op when the
                        // upload state and card insertion arrive in one update.
                        await Task.yield()
                        try? await Task.sleep(for: .milliseconds(100))
                        withAnimation(Theme.springSnappy) {
                            scrollProxy.scrollTo("upload-result", anchor: .center)
                        }
                    }
                }
        }
        .background(Theme.surface)
        .navigationTitle("Record")
        .navigationDestination(for: LibraryItem.self) { item in
            ItemDetailView(item: item)
        }
        .task {
            uploader.resumePendingWork()
            uploadResult = uploader.latestItem ?? uploadResult
        }
        .onDisappear {
            pollingTask?.cancel()
        }
        .onChange(of: recorder.isRecording) { wasRecording, isRecording in
            pulseRing = isRecording && !recorder.isInterrupted
            guard wasRecording != isRecording else { return }
            UIAccessibility.post(
                notification: .announcement,
                argument: isRecording
                    ? "Recording started" : recorder.statusMessage ?? "Recording stopped"
            )
        }
        .onChange(of: recorder.isInterrupted) { _, isInterrupted in
            pulseRing = recorder.isRecording && !isInterrupted
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
                withAnimation(Theme.springSnappy) {
                    recorder.discard(recording)
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

    // MARK: - Capture console

    private var captureConsole: some View {
        VStack(spacing: 20) {
            HStack {
                Label(captureEyebrow, systemImage: captureIcon)
                    .font(Theme.caption(11, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(captureAccent)
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(captureAccent)
                        .frame(width: 7, height: 7)
                    Text(recorder.isRecording ? "ON DEVICE" : "READY")
                        .font(Theme.caption(10, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.textMuted)
                }
            }

            VStack(spacing: 10) {
                Text(recorder.formattedDuration)
                    .font(.system(size: 54, weight: .light, design: .monospaced))
                    .foregroundStyle(recorder.isRecording ? Theme.textPrimary : Theme.textSecondary)
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("recording.timer")

                signalMeter
            }

            captureActionButton

            VStack(spacing: 5) {
                Text(captureTitle)
                    .font(Theme.heading(17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                Text(captureDetail)
                    .font(Theme.caption(12))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if recorder.isRecording {
                Label("Keeps recording when you lock your phone or switch apps", systemImage: "lock.shield")
                    .font(Theme.caption(11))
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusXL)
                .fill(
                    LinearGradient(
                        colors: [captureAccent.opacity(0.11), Theme.surfaceCard, Theme.surfaceElevated],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusXL)
                .stroke(captureAccent.opacity(recorder.isRecording ? 0.42 : 0.2), lineWidth: 1)
        )
        .animation(reduceMotion ? nil : Theme.springGentle, value: recorder.isRecording)
        .animation(reduceMotion ? nil : Theme.springGentle, value: recorder.isStarting)
    }

    private var signalMeter: some View {
        HStack(spacing: 4) {
            ForEach(0..<24, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        recorder.isRecording && !recorder.isInterrupted
                            ? captureAccent
                            : Theme.border
                    )
                    .frame(
                        width: 4,
                        height: recorder.isRecording && !recorder.isInterrupted
                            ? 7 + (27 * recorder.audioLevel * waveformScale(for: index))
                            : 4
                    )
            }
        }
        .frame(height: 34)
        .animation(reduceMotion ? nil : .linear(duration: 0.1), value: recorder.audioLevel)
        .accessibilityHidden(true)
    }

    private var captureActionButton: some View {
        Button {
            if recorder.isRecording {
                recorder.stop()
                pulseRing = false
                Haptics.medium()
            } else {
                error = nil
                recorder.start(contentType: contentType)
                Haptics.medium()
            }
        } label: {
            ZStack {
                if recorder.isRecording && !reduceMotion {
                    Circle()
                        .stroke(Theme.error.opacity(0.26), lineWidth: 2)
                        .frame(width: 94, height: 94)
                        .scaleEffect(pulseRing ? 1.2 : 1)
                        .opacity(pulseRing ? 0 : 0.7)
                        .animation(
                            .easeOut(duration: 1.15).repeatForever(autoreverses: false),
                            value: pulseRing
                        )
                }

                Circle()
                    .fill(Theme.brandGradient)
                    .frame(width: 82, height: 82)
                    .shadow(color: captureAccent.opacity(0.28), radius: 18, y: 7)

                if recorder.isRecording {
                    Circle()
                        .fill(Theme.error)
                        .frame(width: 82, height: 82)
                }

                if recorder.isStarting {
                    ProgressView().tint(.white)
                } else if recorder.isInterrupted {
                    Image(systemName: "stop.fill")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                } else if recorder.isRecording {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.white)
                        .frame(width: 25, height: 25)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 108, height: 108)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isUploading || recorder.isStarting)
        .accessibilityLabel(
            recorder.isStarting
                ? "Preparing microphone"
                : (recorder.isRecording ? "Stop recording" : "Start recording")
        )
        .accessibilityHint(
            recorder.isRecording
                ? "Stops and saves this recording" : "Begins recording from the microphone"
        )
        .accessibilityValue(recorder.isRecording ? recorder.formattedDuration : "Not recording")
    }

    private var captureAccent: Color {
        if recorder.storageIsLow || recorder.isInterrupted { return Theme.warning }
        if recorder.isRecording { return Theme.error }
        return Theme.brand400
    }

    private var captureEyebrow: String {
        if recorder.isStarting { return "PREPARING" }
        if recorder.isInterrupted { return "INTERRUPTED" }
        if recorder.isRecording { return "LIVE CAPTURE" }
        return "QUICK CAPTURE"
    }

    private var captureIcon: String {
        if recorder.isStarting { return "waveform.badge.magnifyingglass" }
        if recorder.isInterrupted { return "pause.circle.fill" }
        if recorder.isRecording { return "record.circle.fill" }
        return "waveform"
    }

    private var captureTitle: String {
        if recorder.isStarting { return "Preparing microphone" }
        if recorder.isInterrupted { return "Recording interrupted" }
        if recorder.isRecording { return "Recording now" }
        if recorder.statusMessage != nil { return "Ready for another recording" }
        return "Ready to record"
    }

    private var captureDetail: String {
        if recorder.isStarting { return "Setting up a secure on-device audio session." }
        if recorder.isInterrupted { return "Another audio source paused capture. Tap stop to save what was recorded." }
        if recorder.isRecording { return "Tap once to stop and save. Upload begins only when you choose Transcribe." }
        if recorder.storageIsLow { return "Free at least 100 MB before starting a new recording." }
        if recorder.statusMessage != nil {
            return "The previous recording is saved. The clock is reset and ready when you are."
        }
        return "Choose a content type, then tap the microphone. Your audio is saved on this iPhone first."
    }

    @ViewBuilder
    private func localRecordingCard(_ recording: LocalRecording) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(
                    systemName: recording.state == .interrupted
                        ? "waveform.badge.exclamationmark"
                        : (recording.isUploadInProgress ? "icloud.and.arrow.up" : "waveform")
                )
                .font(.title3)
                .foregroundStyle(
                    recording.state == .interrupted
                        ? Theme.warning
                        : (recording.state == .uploadFailed ? Theme.error : Theme.brand400)
                )
                .frame(width: 36, height: 36)
                .background(Theme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMedium))

                VStack(alignment: .leading, spacing: 4) {
                    Text(recording.displayTitle)
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(recording.formattedDuration)  ·  \(recording.recoveryDescription)")
                        .font(Theme.caption(12))
                        .foregroundStyle(
                            recording.state == .uploadFailed ? Theme.error : Theme.textSecondary
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)
            }

            if recording.state == .uploading {
                ProgressView(value: recording.uploadProgress ?? 0)
                    .tint(Theme.brand400)
                    .accessibilityLabel("Upload progress")
                    .accessibilityValue(
                        "\(Int(((recording.uploadProgress ?? 0) * 100).rounded())) percent"
                    )
            }

            HStack(spacing: 12) {
                Button {
                    if !recording.isUploadInProgress {
                        error = nil
                        uploader.queue(recording)
                        Haptics.light()
                    }
                } label: {
                    if recording.isUploadInProgress {
                        HStack(spacing: 8) {
                            ProgressView()
                                .tint(.white)
                            Text(uploadButtonTitle(for: recording))
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Label(
                            recording.state == .uploadFailed ? "Retry" : "Transcribe",
                            systemImage: recording.state == .uploadFailed
                                ? "arrow.clockwise" : "arrow.up.circle"
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.brand500)
                .disabled(
                    recording.isUploadInProgress
                        || recorder.isStarting
                        || recorder.isRecording
                )
                .accessibilityIdentifier("recording.transcribe.\(recording.id.uuidString)")

                Button {
                    recordingToDiscard = recording
                } label: {
                    Label("Discard", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .tint(Theme.error)
                .disabled(
                    recording.isUploadInProgress
                        || recorder.isStarting
                        || recorder.isRecording
                )
                .accessibilityIdentifier("recording.discard.\(recording.id.uuidString)")
            }
        }
        .cardStyle()
    }

    private func queueImportedRecording(url: URL, contentType: String) async {
        error = nil
        do {
            let recording = try recorder.importRecording(from: url, contentType: contentType)
            uploader.queue(recording)
            Haptics.light()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }

    private func retryTranscription(id: String) async {
        isUploading = true
        defer { isUploading = false }
        error = nil
        do {
            let result = try await service.retryAudioItem(id)
            withAnimation(Theme.springSnappy) {
                uploadResult = result
            }
            Haptics.light()
            startPolling(id: id)
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
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
                    withAnimation(Theme.springSnappy) {
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
        default:
            return "Transcribe"
        }
    }

    private func waveformScale(for index: Int) -> CGFloat {
        let shape: [CGFloat] = [
            0.35, 0.5, 0.75, 0.55, 0.9, 0.65, 1, 0.7, 0.45, 0.8,
            0.6, 0.95, 0.7, 0.5, 0.85, 0.65, 1, 0.55, 0.75, 0.4,
        ]
        return shape[index % shape.count]
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins):\(String(format: "%02d", secs))"
    }
}
