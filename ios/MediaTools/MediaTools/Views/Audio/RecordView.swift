import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct RecordView: View {
    @State private var recorder = AudioRecorderService()
    @State private var contentType = "general"
    @State private var isUploading = false
    @State private var uploadResult: AudioTranscription?
    @State private var pollingTask: Task<Void, Never>?
    @State private var error: String?
    @State private var showFilePicker = false
    @State private var pulseRing = false

    private let service = MediaToolsService.shared

    private let contentTypes = [
        ("general", "General", "waveform"),
        ("phone_call", "Phone Call", "phone"),
        ("meeting", "Meeting", "person.3"),
        ("voice_memo", "Voice Memo", "bubble.left"),
        ("interview", "Interview", "doc.text"),
        ("lecture", "Lecture", "graduationcap"),
    ]

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
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

                    Spacer()

                    // Recording UI
                    VStack(spacing: 20) {
                        // Timer
                        Text(recorder.formattedDuration)
                            .font(.system(size: 48, weight: .light, design: .monospaced))
                            .foregroundStyle(recorder.isRecording ? Theme.brand400 : Theme.textMuted)

                        // Waveform
                        if recorder.isRecording {
                            HStack(spacing: 3) {
                                ForEach(0..<20, id: \.self) { i in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(
                                            LinearGradient(
                                                colors: [Theme.brand400, Theme.brand500],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            )
                                        )
                                        .frame(
                                            width: 4,
                                            height: 8 + (36 * recorder.audioLevel * waveformScale(for: i))
                                        )
                                }
                            }
                            .frame(height: 44)
                            .animation(.linear(duration: 0.1), value: recorder.audioLevel)
                            .transition(.opacity)
                            .accessibilityHidden(true)
                        }

                        // Record button with pulsing ring
                        Button {
                            if recorder.isRecording {
                                recorder.stop()
                                pulseRing = false
                                Haptics.medium()
                            } else {
                                error = nil
                                recorder.start()
                                Haptics.medium()
                            }
                        } label: {
                            ZStack {
                                // Pulsing outer ring
                                if recorder.isRecording {
                                    Circle()
                                        .stroke(Color.red.opacity(0.3), lineWidth: 3)
                                        .frame(width: 96, height: 96)
                                        .scaleEffect(pulseRing ? 1.2 : 1.0)
                                        .opacity(pulseRing ? 0.0 : 0.6)
                                        .animation(
                                            .easeInOut(duration: 1).repeatForever(autoreverses: false),
                                            value: pulseRing
                                        )

                                    Circle()
                                        .stroke(Color.red.opacity(0.15), lineWidth: 2)
                                        .frame(width: 96, height: 96)
                                        .scaleEffect(pulseRing ? 1.4 : 1.0)
                                        .opacity(pulseRing ? 0.0 : 0.4)
                                        .animation(
                                            .easeInOut(duration: 1.3).repeatForever(autoreverses: false),
                                            value: pulseRing
                                        )
                                }

                                Circle()
                                    .fill(recorder.isRecording ? .red : Theme.brand500)
                                    .frame(width: 72, height: 72)

                                if recorder.isStarting {
                                    ProgressView()
                                        .tint(.white)
                                } else if recorder.isRecording {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(.white)
                                        .frame(width: 24, height: 24)
                                } else {
                                    Circle()
                                        .fill(.white)
                                        .frame(width: 28, height: 28)
                                }
                            }
                            .animation(Theme.springSnappy, value: recorder.isRecording)
                        }
                        .shadow(
                            color: (recorder.isRecording ? Color.red : Theme.brand500).opacity(0.3), radius: 12
                        )
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

                        Text(
                            recorder.isStarting
                                ? "Preparing microphone..."
                                : (recorder.isRecording ? "Tap to stop" : "Tap to record")
                        )
                            .font(Theme.caption())
                            .foregroundStyle(Theme.textSecondary)
                    }

                    Spacer()

                    // Recorded audio actions
                    if let recordingURL = recorder.recordingURL, !recorder.isRecording {
                        VStack(spacing: 12) {
                            HStack {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundStyle(Theme.success)
                                Text("Recording ready")
                                    .font(Theme.body(15, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                            }

                            HStack(spacing: 12) {
                                Button {
                                    Task { await uploadRecording(url: recordingURL) }
                                } label: {
                                    if isUploading {
                                        HStack(spacing: 8) {
                                            ProgressView()
                                                .tint(.white)
                                            Text("Uploading...")
                                        }
                                        .frame(maxWidth: .infinity)
                                    } else {
                                        Label("Transcribe", systemImage: "arrow.up.circle")
                                            .frame(maxWidth: .infinity)
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.brand500)
                                .disabled(isUploading || recorder.isStarting)

                                Button {
                                    withAnimation(Theme.springSnappy) {
                                        recorder.discard()
                                    }
                                } label: {
                                    Label("Discard", systemImage: "trash")
                                }
                                .buttonStyle(.bordered)
                                .tint(Theme.error)
                                .disabled(isUploading || recorder.isStarting)
                            }
                        }
                        .cardStyle()
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

                                if let text = result.transcriptText, !text.isEmpty {
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
                                    await uploadRecording(url: url)
                                }
                            }
                        case .failure(let error):
                            self.error = error.localizedDescription
                        }
                    }
                }
                .frame(minHeight: geometry.size.height)
                .padding(.top, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Theme.surface)
        .navigationTitle("Record")
        .navigationDestination(for: LibraryItem.self) { item in
            ItemDetailView(item: item)
        }
        .onDisappear {
            pollingTask?.cancel()
        }
        .onChange(of: recorder.isRecording) { _, isRecording in
            pulseRing = isRecording
        }
    }

    private func uploadRecording(url: URL) async {
        isUploading = true
        defer { isUploading = false }
        error = nil

        do {
            let filename = url.lastPathComponent
            let result = try await service.uploadAudio(
                fileURL: url,
                filename: filename,
                mimeType: mimeType(for: url),
                contentType: contentType
            )
            withAnimation(Theme.springSnappy) {
                uploadResult = result
                if recorder.recordingURL == url {
                    recorder.discard()
                }
            }
            Haptics.light()
            startPolling(id: result.id)
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
                uploadResult?.status != "completed",
                uploadResult?.status != "failed"
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

    private func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
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

// MARK: - Audio Recorder

@MainActor
@Observable
final class AudioRecorderService {
    var isRecording = false
    var isStarting = false
    var recordingURL: URL?
    var duration: TimeInterval = 0
    var audioLevel: CGFloat = 0
    var errorMessage: String?
    var permissionDenied = false

    private var audioRecorder: AVAudioRecorder?
    private var timer: Timer?

    var formattedDuration: String {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    func start() {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        errorMessage = nil
        permissionDenied = false
        let session = AVAudioSession.sharedInstance()

        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard granted else {
                    self.isStarting = false
                    self.permissionDenied = true
                    self.errorMessage =
                        "Microphone access is required to record. You can enable it in Settings."
                    return
                }
                self.startRecording(session: session)
            }
        }
    }

    private func startRecording(session: AVAudioSession) {
        defer { isStarting = false }
        let previousRecordingURL = recordingURL
        do {
            let bluetoothInput: AVAudioSession.CategoryOptions
            #if compiler(>=6.2)
            bluetoothInput = .allowBluetoothHFP
            #else
            // Xcode 16.4's iOS 18 SDK uses the pre-rename spelling.
            bluetoothInput = .allowBluetooth
            #endif
            try session.setCategory(
                .playAndRecord, mode: .default, options: [.defaultToSpeaker, bluetoothInput])
            try session.setActive(true)
        } catch {
            errorMessage = "Could not start the audio session: \(error.localizedDescription)"
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        do {
            let replacementRecorder = try AVAudioRecorder(url: url, settings: settings)
            replacementRecorder.isMeteringEnabled = true
            guard replacementRecorder.record() else {
                throw APIError.invalidFile(message: "The recorder could not start.")
            }

            // Keep the previous take recoverable until the replacement has
            // actually started. A permission, session, or recorder failure must
            // never destroy audio that was already ready to upload.
            if let previousRecordingURL, previousRecordingURL != url {
                try? FileManager.default.removeItem(at: previousRecordingURL)
            }
            audioRecorder = replacementRecorder
            recordingURL = url
            isRecording = true
            duration = 0
            audioLevel = 0

            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateMeters()
                }
            }
        } catch {
            audioRecorder = nil
            try? FileManager.default.removeItem(at: url)
            errorMessage = "Recording failed: \(error.localizedDescription)"
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func updateMeters() {
        guard let audioRecorder else { return }
        audioRecorder.updateMeters()
        duration = audioRecorder.currentTime
        let power = max(-60, min(0, audioRecorder.averagePower(forChannel: 0)))
        audioLevel = CGFloat(pow(10, power / 20))
    }

    func stop() {
        if let audioRecorder {
            duration = audioRecorder.currentTime
        }
        audioRecorder?.stop()
        audioRecorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        audioLevel = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func discard() {
        if isRecording { stop() }
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
        duration = 0
        audioLevel = 0
    }
}
