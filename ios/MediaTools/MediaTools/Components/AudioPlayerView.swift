import SwiftUI
import AVFoundation

/// In-app audio playback for recorded/uploaded audio.
struct AudioPlayerView: View {
    let audioId: String
    @State private var player = AudioPlayerService()
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.orange)
                Text("Playback")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }

            if isLoading {
                ProgressView("Loading audio...")
                    .font(.caption)
            } else if let error {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                // Playback controls
                VStack(spacing: 8) {
                    // Progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.secondary.opacity(0.2))
                                .frame(height: 4)

                            RoundedRectangle(cornerRadius: 2)
                                .fill(.orange)
                                .frame(width: geo.size.width * player.progress, height: 4)
                        }
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let pct = value.location.x / geo.size.width
                                    player.seek(to: max(0, min(1, pct)))
                                }
                        )
                    }
                    .frame(height: 4)

                    // Time + controls
                    HStack {
                        Text(player.formattedCurrentTime)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)

                        Spacer()

                        // Rewind 15s
                        Button {
                            player.skip(seconds: -15)
                        } label: {
                            Image(systemName: "gobackward.15")
                                .font(.title3)
                        }

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
                                .foregroundStyle(.orange)
                        }

                        // Forward 15s
                        Button {
                            player.skip(seconds: 15)
                        } label: {
                            Image(systemName: "goforward.15")
                                .font(.title3)
                        }

                        Spacer()

                        Text(player.formattedDuration)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    // Speed control
                    HStack(spacing: 8) {
                        ForEach([0.5, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                            Button {
                                player.setSpeed(Float(speed))
                            } label: {
                                Text(speed == 1.0 ? "1x" : "\(speed, specifier: "%.1g")x")
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(player.speed == Float(speed) ? Color.orange.opacity(0.2) : Color.clear)
                                    .foregroundStyle(player.speed == Float(speed) ? .orange : .secondary)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .background(.orange.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task {
            await loadAudio()
        }
        .onDisappear {
            player.stop()
        }
    }

    private func loadAudio() async {
        isLoading = true
        do {
            let playbackURL: PlaybackURLResponse = try await APIClient.shared.get("/audio/transcriptions/\(audioId)/playback")
            if let url = URL(string: playbackURL.url) {
                player.load(url: url)
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

@Observable
class AudioPlayerService {
    var isPlaying = false
    var progress: CGFloat = 0
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var speed: Float = 1.0

    private var avPlayer: AVPlayer?
    private var timeObserver: Any?

    var formattedCurrentTime: String {
        formatTime(currentTime)
    }

    var formattedDuration: String {
        formatTime(duration)
    }

    func load(url: URL) {
        let item = AVPlayerItem(url: url)
        avPlayer = AVPlayer(playerItem: item)

        // Observe time
        timeObserver = avPlayer?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self, let item = self.avPlayer?.currentItem else { return }
            let current = time.seconds
            let total = item.duration.seconds
            guard total.isFinite && total > 0 else { return }
            self.currentTime = current
            self.duration = total
            self.progress = CGFloat(current / total)
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
        avPlayer?.pause()
        if let observer = timeObserver {
            avPlayer?.removeTimeObserver(observer)
        }
        avPlayer = nil
        isPlaying = false
    }

    func seek(to fraction: CGFloat) {
        guard duration > 0 else { return }
        let time = CMTime(seconds: Double(fraction) * duration, preferredTimescale: 600)
        avPlayer?.seek(to: time)
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
}
