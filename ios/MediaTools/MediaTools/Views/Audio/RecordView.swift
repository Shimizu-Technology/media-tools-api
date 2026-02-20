import SwiftUI
import AVFoundation

struct RecordView: View {
    @State private var recorder = AudioRecorderService()
    @State private var contentType = "general"
    @State private var isUploading = false
    @State private var uploadResult: AudioTranscription?
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
                                .frame(width: 4, height: CGFloat.random(in: 8...40))
                                .animation(
                                    .easeInOut(duration: 0.3)
                                        .repeatForever()
                                        .delay(Double(i) * 0.05),
                                    value: recorder.isRecording
                                )
                        }
                    }
                    .frame(height: 44)
                    .transition(.opacity)
                }

                // Record button with pulsing ring
                Button {
                    if recorder.isRecording {
                        recorder.stop()
                        pulseRing = false
                        Haptics.medium()
                    } else {
                        recorder.start()
                        pulseRing = true
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

                        if recorder.isRecording {
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
                .shadow(color: (recorder.isRecording ? Color.red : Theme.brand500).opacity(0.3), radius: 12)

                Text(recorder.isRecording ? "Tap to stop" : "Tap to record")
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
                        .disabled(isUploading)

                        Button {
                            withAnimation(Theme.springSnappy) {
                                recorder.discard()
                            }
                        } label: {
                            Label("Discard", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.error)
                    }
                }
                .cardStyle()
                .padding(.horizontal)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Upload result
            if let uploadResult {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success)
                    Text("Uploaded! Processing transcription...")
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.bottom, 8)
                .transition(.opacity)
            }

            if let error {
                Text(error)
                    .font(Theme.caption())
                    .foregroundStyle(Theme.error)
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
            .padding(.bottom, 20)
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        Task { await uploadRecording(url: url) }
                    }
                case .failure(let error):
                    self.error = error.localizedDescription
                }
            }
        }
        .background(Theme.surface)
        .navigationTitle("Record")
    }

    private func uploadRecording(url: URL) async {
        isUploading = true
        error = nil
        defer { isUploading = false }

        do {
            let data = try Data(contentsOf: url)
            let filename = url.lastPathComponent
            uploadResult = try await service.uploadAudio(
                data: data,
                filename: filename,
                contentType: contentType
            )
            withAnimation(Theme.springSnappy) {
                recorder.discard()
            }
            await service.loadAudioItems()
            Haptics.success()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }
}

// MARK: - Audio Recorder

@Observable
class AudioRecorderService {
    var isRecording = false
    var recordingURL: URL?
    var duration: TimeInterval = 0

    private var audioRecorder: AVAudioRecorder?
    private var timer: Timer?

    var formattedDuration: String {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    func start() {
        let session = AVAudioSession.sharedInstance()

        AVAudioApplication.requestRecordPermission { granted in
            guard granted else {
                print("Microphone permission denied")
                return
            }
            DispatchQueue.main.async {
                self.startRecording(session: session)
            }
        }
    }

    private func startRecording(session: AVAudioSession) {
        do {
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
        } catch {
            print("Audio session setup failed: \(error)")
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
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.record()
            recordingURL = url
            isRecording = true
            duration = 0

            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.duration += 1
            }
        } catch {
            print("Recording failed: \(error)")
        }
    }

    func stop() {
        audioRecorder?.stop()
        timer?.invalidate()
        timer = nil
        isRecording = false
    }

    func discard() {
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
        duration = 0
    }
}
