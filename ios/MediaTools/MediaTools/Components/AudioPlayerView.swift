import SwiftUI
import AVFoundation

/// In-app audio playback for recorded/uploaded audio. Quiet until it is used: one
/// line under the title, with skip and speed appearing once playback has started.
struct AudioPlayerView: View {
    let player: AudioPlayerService
    let audioId: String
    let knownDuration: TimeInterval?
    @Binding private var seekTime: TimeInterval?
    @State private var isLoading = true
    @State private var error: String?
    @State private var playbackNotice: String?
    @State private var hasStarted = false
    @Environment(RecordingCoordinator.self) private var recorder
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        player: AudioPlayerService,
        audioId: String,
        knownDuration: TimeInterval? = nil,
        seekTime: Binding<TimeInterval?> = .constant(nil)
    ) {
        self.player = player
        self.audioId = audioId
        self.knownDuration = knownDuration
        self._seekTime = seekTime
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isLoading {
                ProgressNote(text: "Loading audio…")
                    .frame(minHeight: 44)
            } else if let error {
                NoticeRow(systemImage: "exclamationmark.circle", title: error)
                    .frame(minHeight: 44)
            } else {
                HStack(spacing: 10) {
                    playButton
                    PlaybackTrack(player: player)
                    if !dynamicTypeSize.isAccessibilitySize {
                        timeLabel
                    }
                }
                if dynamicTypeSize.isAccessibilitySize {
                    timeLabel
                }

                if hasStarted {
                    secondaryControls
                        .transition(.opacity)
                }

                if let playbackNotice {
                    Text(playbackNotice)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .animation(Theme.quick, value: hasStarted)
        .task {
            await loadAudio()
        }
        .onChange(of: seekTime) {
            guard let seekTime else { return }
            player.seek(seconds: seekTime)
            startPlayback()
            self.seekTime = nil
        }
        .onChange(of: recorder.captureState) { _, state in
            // Starting a capture with the Action Button must not record this
            // audio through the speaker.
            if state != .idle { player.pause() }
        }
        .onDisappear {
            player.stop()
        }
    }

    private var timeText: String {
        "\(player.formattedCurrentTime) of \(player.formattedDuration)"
    }

    private var timeLabel: some View {
        Text(timeText)
            .font(.footnote.monospacedDigit())
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .accessibilityHidden(true)
    }

    private var playButton: some View {
        Button {
            if player.isPlaying {
                player.pause()
            } else {
                startPlayback()
            }
        } label: {
            // The glyph has a fixed circle to stay inside. Its label is what scales.
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.subheadline)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .foregroundStyle(Theme.onAccent)
                .frame(width: 36, height: 36)
                .background(Theme.accentFill, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(PressFeedbackButtonStyle())
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
        .accessibilityValue(timeText)
    }

    private var secondaryControls: some View {
        HStack(spacing: 4) {
            Button {
                player.skip(seconds: -15)
            } label: {
                Image(systemName: "gobackward.15")
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(player.duration <= 0)
            .accessibilityLabel("Back 15 seconds")

            Button {
                player.skip(seconds: 15)
            } label: {
                Image(systemName: "goforward.15")
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(player.duration <= 0)
            .accessibilityLabel("Forward 15 seconds")

            Spacer(minLength: 0)

            Menu {
                ForEach(Array(zip([0.5, 1.0, 1.25, 1.5, 2.0], ["0.5x", "1x", "1.25x", "1.5x", "2x"])), id: \.0) { speed, label in
                    Button {
                        player.setSpeed(Float(speed))
                    } label: {
                        if player.speed == Float(speed) {
                            Label(label, systemImage: "checkmark")
                        } else {
                            Text(label)
                        }
                    }
                }
            } label: {
                Text(speedLabel)
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Playback speed")
            .accessibilityValue(speedLabel)
        }
        .foregroundStyle(Theme.accent)
    }

    private var speedLabel: String {
        let value = player.speed
        return value == value.rounded() ? "\(Int(value))x" : "\(value)x"
    }

    private var captureIsActive: Bool {
        recorder.isRecording || recorder.isStarting
    }

    /// Capture owns the audio session while it runs. Claiming it for playback
    /// would interrupt the recording, so playback waits until capture finishes.
    private func startPlayback() {
        guard !captureIsActive else {
            playbackNotice = "Playback is available after the recording stops."
            return
        }
        playbackNotice = nil
        hasStarted = true
        player.play()
    }

    private func loadAudio() async {
        isLoading = true
        do {
            let playbackURL: PlaybackURLResponse = try await APIClient.shared.get("/audio/transcriptions/\(audioId)/audio")
            if let url = URL(string: playbackURL.url) {
                player.load(url: url, knownDuration: knownDuration)
                if let seekTime {
                    player.seek(seconds: seekTime)
                    startPlayback()
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

/// A thin line with a thumb. The strip around it is a full 44 points tall.
private struct PlaybackTrack: View {
    let player: AudioPlayerService

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.separator)
                    .frame(height: 3)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: geometry.size.width * player.progress, height: 3)
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 11, height: 11)
                    .offset(x: geometry.size.width * player.progress - 5.5)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard geometry.size.width > 0 else { return }
                        let fraction = value.location.x / geometry.size.width
                        player.seek(to: max(0, min(1, fraction)))
                    }
            )
        }
        .frame(height: 44)
        .allowsHitTesting(player.duration > 0)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(player.formattedCurrentTime) of \(player.formattedDuration)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: player.skip(seconds: 15)
            case .decrement: player.skip(seconds: -15)
            @unknown default: break
            }
        }
    }
}

/// Takes over from the inline control when it has scrolled away, so a timestamp
/// tapped deep in the transcript can still be paused from where you are reading.
struct AudioMiniBar: View {
    let player: AudioPlayerService

    var body: some View {
        HStack(spacing: 10) {
            Button {
                player.pause()
            } label: {
                Image(systemName: "pause.fill")
                    .font(.subheadline)
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Pause")
            PlaybackTrack(player: player)
            Text(player.formattedCurrentTime)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .fixedSize()
                .accessibilityHidden(true)
        }
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
        // Switch to playback mode so audio comes from speaker, not earpiece.
        // This happens on play rather than load, because merely opening an item
        // during a recording must not touch the session capture is using.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Audio session setup failed: \(error)")
        }
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
