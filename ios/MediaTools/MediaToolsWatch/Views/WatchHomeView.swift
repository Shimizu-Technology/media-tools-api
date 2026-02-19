import SwiftUI

/// Main Watch view — recording button + recent items.
struct WatchHomeView: View {
    @EnvironmentObject var connectivity: WatchConnectivityService
    @EnvironmentObject var recorder: WatchRecorderService
    @State private var selectedContentType = "voice_memo"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Current transcription status
                    if let current = connectivity.currentTranscription {
                        TranscriptionStatusCard(transcription: current)
                    }

                    // Record button
                    if recorder.isRecording {
                        RecordingActiveView()
                    } else {
                        RecordButton()
                    }

                    // Content type selector (compact)
                    ContentTypePicker(selected: $selectedContentType)

                    // Recent items
                    if !connectivity.recentItems.isEmpty {
                        RecentItemsList()
                    }

                    // Connection status
                    ConnectionBadge()
                }
                .padding(.horizontal, 4)
            }
            .navigationTitle("Media Tools")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Record Button

struct RecordButton: View {
    @EnvironmentObject var recorder: WatchRecorderService

    var body: some View {
        Button {
            WKInterfaceDevice.current().play(.start)
            recorder.startRecording()
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color(red: 47/255, green: 158/255, blue: 143/255).opacity(0.2))
                        .frame(width: 80, height: 80)

                    Circle()
                        .fill(Color(red: 47/255, green: 158/255, blue: 143/255))
                        .frame(width: 56, height: 56)

                    Image(systemName: "mic.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                }

                Text("Tap to Record")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 8)
    }
}

// MARK: - Recording Active

struct RecordingActiveView: View {
    @EnvironmentObject var recorder: WatchRecorderService
    @EnvironmentObject var connectivity: WatchConnectivityService
    @State private var selectedContentType = "voice_memo"

    var body: some View {
        VStack(spacing: 12) {
            // Timer
            Text(recorder.formattedDuration)
                .font(.system(size: 32, weight: .light, design: .monospaced))
                .foregroundStyle(Color(red: 47/255, green: 158/255, blue: 143/255))

            // Waveform bars
            HStack(spacing: 2) {
                ForEach(0..<12, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color(red: 47/255, green: 158/255, blue: 143/255))
                        .frame(width: 3, height: barHeight(for: i))
                }
            }
            .frame(height: 24)

            // Stop button
            Button {
                WKInterfaceDevice.current().play(.stop)
                if let fileURL = recorder.stopRecording() {
                    connectivity.sendAudioToPhone(
                        fileURL: fileURL,
                        duration: recorder.duration,
                        contentType: selectedContentType
                    )
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(.red)
                        .frame(width: 56, height: 56)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(.white)
                        .frame(width: 20, height: 20)
                }
            }
            .buttonStyle(.plain)

            if let size = recorder.fileSizeString {
                Text(size)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let base: CGFloat = 4
        let level = CGFloat(recorder.audioLevel)
        let variation = sin(Double(index) * 0.8 + Date().timeIntervalSince1970 * 3) * 0.3 + 0.7
        return base + (20 * level * CGFloat(variation))
    }
}

// MARK: - Content Type Picker

struct ContentTypePicker: View {
    @Binding var selected: String

    private let types = [
        ("voice_memo", "Memo", "bubble.left"),
        ("meeting", "Meeting", "person.3"),
        ("lecture", "Lecture", "graduationcap"),
        ("phone_call", "Call", "phone"),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(types, id: \.0) { type in
                    Button {
                        selected = type.0
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: type.2)
                                .font(.system(size: 9))
                            Text(type.1)
                                .font(.system(size: 10))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(selected == type.0
                                      ? Color(red: 47/255, green: 158/255, blue: 143/255)
                                      : Color.white.opacity(0.1))
                        )
                        .foregroundStyle(selected == type.0 ? .white : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Transcription Status Card

struct TranscriptionStatusCard: View {
    let transcription: WatchTranscription

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                statusIcon
                Text(statusText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(statusColor)
            }

            Text(transcription.title)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            if transcription.wordCount > 0 {
                Text("\(transcription.wordCount) words")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(statusColor.opacity(0.1))
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch transcription.status {
        case .transferring, .uploading:
            ProgressView()
                .scaleEffect(0.7)
        case .pending, .processing:
            ProgressView()
                .scaleEffect(0.7)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var statusText: String {
        switch transcription.status {
        case .transferring: "Sending..."
        case .uploading: "Uploading..."
        case .pending: "Queued"
        case .processing: "Transcribing..."
        case .completed: "Complete"
        case .failed: "Failed"
        }
    }

    private var statusColor: Color {
        switch transcription.status {
        case .transferring, .uploading, .pending, .processing: .orange
        case .completed: .green
        case .failed: .red
        }
    }
}

// MARK: - Recent Items List

struct RecentItemsList: View {
    @EnvironmentObject var connectivity: WatchConnectivityService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(connectivity.recentItems) { item in
                HStack(spacing: 6) {
                    Circle()
                        .fill(item.status == "completed" ? .green : .orange)
                        .frame(width: 6, height: 6)

                    Text(item.title)
                        .font(.caption2)
                        .lineLimit(1)

                    Spacer()

                    if item.wordCount > 0 {
                        Text("\(item.wordCount)w")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Connection Badge

struct ConnectionBadge: View {
    @EnvironmentObject var connectivity: WatchConnectivityService

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(connectivity.isPhoneReachable ? .green : .orange)
                .frame(width: 5, height: 5)
            Text(connectivity.isPhoneReachable ? "iPhone connected" : "Direct mode")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }
}
