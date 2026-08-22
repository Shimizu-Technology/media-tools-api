import SwiftUI
import AVFoundation

/// In-app audio playback for recorded/uploaded audio.
struct AudioPlayerView: View {
    let audioId: String
    let knownDuration: TimeInterval?
    @Binding private var seekTime: TimeInterval?
    @State private var player = AudioPlayerService()
    @State private var isLoading = true
    @State private var error: String?

    init(
        audioId: String,
        knownDuration: TimeInterval? = nil,
        seekTime: Binding<TimeInterval?> = .constant(nil)
    ) {
        self.audioId = audioId
        self.knownDuration = knownDuration
        self._seekTime = seekTime
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(Theme.audioColor)
                Text("Playback")
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(Theme.audioColor)
                    Text("Loading audio...")
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.vertical, 8)
            } else if let error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.audioColor)
                    Text(error)
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                // Playback controls
                VStack(spacing: 10) {
                    // Progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Theme.surfaceOverlay)
                                .frame(height: 6)

                            RoundedRectangle(cornerRadius: 3)
                                .fill(Theme.audioColor)
                                .frame(width: geo.size.width * player.progress, height: 6)

                            // Scrubber dot
                            Circle()
                                .fill(Theme.audioColor)
                                .frame(width: 14, height: 14)
                                .shadow(color: Theme.audioColor.opacity(0.4), radius: 4)
                                .offset(x: geo.size.width * player.progress - 7)
                        }
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let pct = value.location.x / geo.size.width
                                    player.seek(to: max(0, min(1, pct)))
                                }
                        )
                    }
                    .frame(height: 14)
                    .allowsHitTesting(player.duration > 0)

                    // Time + controls
                    HStack {
                        Text(player.formattedCurrentTime)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)

                        Spacer()

                        // Rewind 15s
                        Button {
                            player.skip(seconds: -15)
                        } label: {
                            Image(systemName: "gobackward.15")
                                .font(.title3)
                        }
                        .disabled(player.duration <= 0)

                        // Play/Pause
                        Button {
                            if player.isPlaying {
                                player.pause()
                            } else {
                                player.play()
                            }
                        } label: {
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.largeTitle)
                                .foregroundStyle(Theme.audioColor)
                        }

                        // Forward 15s
                        Button {
                            player.skip(seconds: 15)
                        } label: {
                            Image(systemName: "goforward.15")
                                .font(.title3)
                        }
                        .disabled(player.duration <= 0)

                        Spacer()

                        Text(player.formattedDuration)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }

                    // Speed control
                    HStack(spacing: 6) {
                        ForEach(Array(zip([0.5, 1.0, 1.25, 1.5, 2.0], ["0.5x", "1x", "1.25x", "1.5x", "2x"])), id: \.0) { speed, label in
                            Button {
                                player.setSpeed(Float(speed))
                            } label: {
                                Text(label)
                                    .font(Theme.caption(11, weight: .semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(player.speed == Float(speed) ? Theme.audioColor.opacity(0.2) : Theme.surfaceCard)
                                    .foregroundStyle(player.speed == Float(speed) ? Theme.audioColor : Theme.textSecondary)
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule()
                                            .stroke(player.speed == Float(speed) ? Theme.audioColor.opacity(0.4) : Theme.borderSubtle, lineWidth: 1)
                                    )
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Theme.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusMedium)
                .stroke(Theme.audioColor.opacity(0.2), lineWidth: 1)
        )
        .task {
            await loadAudio()
        }
        .onChange(of: seekTime) {
            guard let seekTime else { return }
            player.seek(seconds: seekTime)
            player.play()
            self.seekTime = nil
        }
        .onDisappear {
            player.stop()
        }
    }

    private func loadAudio() async {
        isLoading = true
        do {
            let playbackURL: PlaybackURLResponse = try await APIClient.shared.get("/audio/transcriptions/\(audioId)/audio")
            if let url = URL(string: playbackURL.url) {
                player.load(url: url, knownDuration: knownDuration)
                if let seekTime {
                    player.seek(seconds: seekTime)
                    player.play()
                    self.seekTime = nil
                }
            } else {
                error = "Invalid audio URL"
            }
        } catch {
            self.error = "Audio not available for playback"
        }
        isLoading = false
    }
}

struct PlaybackURLResponse: Codable {
    let url: String
}

// MARK: - Audio Player Service

@MainActor
@Observable
class AudioPlayerService {
    var isPlaying = false
    var progress: CGFloat = 0
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var speed: Float = 1.0

    private var avPlayer: AVPlayer?
    private var timeObserver: Any?
    private var durationLoadTask: Task<Void, Never>?

    var formattedCurrentTime: String {
        formatTime(currentTime)
    }

    var formattedDuration: String {
        formatTime(duration)
    }

    func load(url: URL, knownDuration: TimeInterval? = nil) {
        stop()
        currentTime = 0
        progress = 0
        duration = Self.validDuration(knownDuration) ?? 0

        // Switch to playback mode so audio comes from speaker, not earpiece
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Audio session setup failed: \(error)")
        }

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        avPlayer = AVPlayer(playerItem: item)

        // The API already knows the recording duration, so render that value
        // immediately. Then replace it with the asset's authoritative duration
        // as soon as AVFoundation has loaded the remote metadata.
        durationLoadTask = Task { [weak self] in
            do {
                let loadedDuration = try await asset.load(.duration).seconds
                guard !Task.isCancelled,
                      let loadedDuration = Self.validDuration(loadedDuration)
                else { return }
                self?.duration = loadedDuration
            } catch {
                // The server-provided fallback remains usable when the remote
                // asset cannot expose its metadata before playback begins.
            }
        }

        // Observe time
        timeObserver = avPlayer?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { time in
            let current = time.seconds
            Task { @MainActor [weak self] in
                guard let self else { return }
                let total = self.duration
                guard total.isFinite && total > 0 else { return }
                self.currentTime = current
                self.progress = min(1, max(0, CGFloat(current / total)))
            }
        }
    }

    func play() {
        avPlayer?.rate = speed
        isPlaying = true
    }

    func pause() {
        avPlayer?.pause()
        isPlaying = false
    }

    func stop() {
        durationLoadTask?.cancel()
        durationLoadTask = nil
        avPlayer?.pause()
        if let observer = timeObserver {
            avPlayer?.removeTimeObserver(observer)
        }
        timeObserver = nil
        avPlayer = nil
        isPlaying = false
    }

    func seek(to fraction: CGFloat) {
        guard duration > 0 else { return }
        let time = CMTime(seconds: Double(fraction) * duration, preferredTimescale: 600)
        avPlayer?.seek(to: time)
    }

    func seek(seconds: TimeInterval) {
        let target = duration > 0 ? min(duration, max(0, seconds)) : max(0, seconds)
        avPlayer?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func skip(seconds: Double) {
        guard let player = avPlayer else { return }
        let current = player.currentTime().seconds
        let target = max(0, min(duration, current + seconds))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func setSpeed(_ speed: Float) {
        self.speed = speed
        if isPlaying {
            avPlayer?.rate = speed
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite else { return "0:00" }
        let mins = Int(time) / 60
        let secs = Int(time) % 60
        return "\(mins):\(String(format: "%02d", secs))"
    }

    private static func validDuration(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}
