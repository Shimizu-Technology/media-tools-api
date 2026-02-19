import Foundation
import AVFoundation
import Combine

/// Audio recording service for Apple Watch.
/// Records m4a audio using AVAudioRecorder, tracks duration.
final class WatchRecorderService: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var duration: TimeInterval = 0
    @Published var recordingURL: URL?
    @Published var audioLevel: Float = 0 // For waveform visualization

    private var audioRecorder: AVAudioRecorder?
    private var timer: Timer?
    private var levelTimer: Timer?

    var formattedDuration: String {
        let hours = Int(duration) / 3600
        let mins = (Int(duration) % 3600) / 60
        let secs = Int(duration) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        }
        return String(format: "%02d:%02d", mins, secs)
    }

    /// Start recording audio on the Watch.
    func startRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
        } catch {
            print("Watch audio session setup failed: \(error)")
            return
        }

        // Save to documents directory (persists between launches)
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let filename = "watch-\(Int(Date().timeIntervalSince1970)).m4a"
        let url = documentsPath.appendingPathComponent(filename)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 22050.0,          // Lower sample rate for Watch (saves space)
            AVNumberOfChannelsKey: 1,           // Mono
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey: 64000,         // 64kbps — good balance of quality vs size
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.isMeteringEnabled = true // For level visualization
            audioRecorder?.delegate = self
            audioRecorder?.record()

            recordingURL = url
            isRecording = true
            duration = 0
            audioLevel = 0

            // Duration timer
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.duration += 1
            }

            // Audio level timer (for waveform)
            levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.audioRecorder?.updateMeters()
                let level = self?.audioRecorder?.averagePower(forChannel: 0) ?? -160
                // Normalize: -160..0 dB → 0..1
                let normalized = max(0, (level + 50) / 50)
                self?.audioLevel = normalized
            }

        } catch {
            print("Watch recording failed to start: \(error)")
        }
    }

    /// Stop recording and return the file URL.
    func stopRecording() -> URL? {
        audioRecorder?.stop()
        timer?.invalidate()
        timer = nil
        levelTimer?.invalidate()
        levelTimer = nil
        isRecording = false
        audioLevel = 0

        // Deactivate audio session
        try? AVAudioSession.sharedInstance().setActive(false)

        return recordingURL
    }

    /// Discard the current recording.
    func discardRecording() {
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
        duration = 0
    }

    /// Get file size of current recording.
    var fileSizeString: String? {
        guard let url = recordingURL else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return nil }

        if size < 1024 {
            return "\(size) B"
        } else if size < 1024 * 1024 {
            return "\(size / 1024) KB"
        } else {
            return String(format: "%.1f MB", Double(size) / 1_048_576)
        }
    }
}

// MARK: - AVAudioRecorderDelegate

extension WatchRecorderService: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            print("Watch recording finished unsuccessfully")
            DispatchQueue.main.async {
                self.isRecording = false
            }
        }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        print("Watch recording encode error: \(error?.localizedDescription ?? "unknown")")
        DispatchQueue.main.async {
            self.isRecording = false
        }
    }
}
