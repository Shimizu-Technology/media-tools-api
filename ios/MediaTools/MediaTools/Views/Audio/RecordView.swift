import SwiftUI
import AVFoundation

struct RecordView: View {
    @State private var recorder = AudioRecorderService()
    @State private var contentType = "general"
    @State private var isUploading = false
    @State private var uploadResult: AudioTranscription?
    @State private var error: String?
    @State private var showFilePicker = false

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
                Text("Content Type")
                    .font(.subheadline.weight(.medium))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(contentTypes, id: \.0) { type in
                            Button {
                                contentType = type.0
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: type.2)
                                        .font(.caption)
                                    Text(type.1)
                                        .font(.caption)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(contentType == type.0 ? Theme.brand500 : Color.secondary.opacity(0.1))
                                .foregroundStyle(contentType == type.0 ? .white : .primary)
                                .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)

            Spacer()

            // Recording UI
            VStack(spacing: 20) {
                // Timer
                Text(recorder.formattedDuration)
                    .font(.system(size: 48, weight: .light, design: .monospaced))
                    .foregroundStyle(recorder.isRecording ? Theme.brand500 : .secondary)

                // Waveform placeholder
                if recorder.isRecording {
                    HStack(spacing: 3) {
                        ForEach(0..<20, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Theme.brand500)
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
                }

                // Record button
                Button {
                    if recorder.isRecording {
                        recorder.stop()
                    } else {
                        recorder.start()
                    }
                } label: {
                    ZStack {
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
                }
                .shadow(color: (recorder.isRecording ? Color.red : Theme.brand500).opacity(0.3), radius: 12)

                Text(recorder.isRecording ? "Tap to stop" : "Tap to record")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            // Recorded audio actions
            if let recordingURL = recorder.recordingURL, !recorder.isRecording {
                VStack(spacing: 12) {
                    Text("Recording ready")
                        .font(.subheadline.weight(.medium))

                    HStack(spacing: 12) {
                        Button {
                            Task { await uploadRecording(url: recordingURL) }
                        } label: {
                            if isUploading {
                                HStack {
                                    ProgressView()
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
                            recorder.discard()
                        } label: {
                            Label("Discard", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.error)
                    }
                }
                .padding()
                .background(.secondary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
            }

            // Upload result
            if let uploadResult {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Uploaded! Processing transcription...")
                        .font(.caption)
                }
                .padding(.bottom, 8)
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.bottom, 8)
            }

            // File upload option
            Button {
                showFilePicker = true
            } label: {
                Label("Upload Audio File", systemImage: "square.and.arrow.up")
                    .font(.subheadline)
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
            recorder.discard()
            await service.loadAudioItems()
        } catch {
            self.error = error.localizedDescription
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
