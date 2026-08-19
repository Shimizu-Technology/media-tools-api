import AppIntents
import SwiftUI
import WidgetKit

@main
struct MediaToolsWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuickRecordWidget()
        QuickRecordControl()
        RecordingLiveActivity()
    }
}

// MARK: - Home and Lock Screen widget

private struct QuickRecordEntry: TimelineEntry {
    let date: Date
}

private struct QuickRecordProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickRecordEntry {
        QuickRecordEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickRecordEntry) -> Void) {
        completion(QuickRecordEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickRecordEntry>) -> Void) {
        completion(Timeline(entries: [QuickRecordEntry(date: .now)], policy: .never))
    }
}

private struct QuickRecordWidget: Widget {
    let kind = "com.shimizutechnology.mediatools.quick-record-widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuickRecordProvider()) { _ in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "waveform.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.teal)
                    Spacer()
                    Text("MEDIA TOOLS")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button(intent: QuickRecordIntent()) {
                    Label("Quick Record", systemImage: "mic.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Text("Tap again or use the Live Activity to stop.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Quick Record")
        .description("Start or stop a Media Tools recording without opening the app.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Control Center, Lock Screen, and Action Button control

private struct QuickRecordControl: ControlWidget {
    static let kind = "com.shimizutechnology.mediatools.quick-record-control"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: QuickRecordIntent()) {
                Label("Quick Record", systemImage: "mic.fill")
            }
        }
        .displayName("Quick Record")
        .description("Start or stop a private Media Tools recording.")
    }
}

// MARK: - Lock Screen and Dynamic Island

private struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.18))
                    Image(systemName: context.state.isInterrupted ? "pause.fill" : "waveform")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.red)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text(context.state.isInterrupted ? "Recording paused" : "Recording")
                        .font(.headline)
                    Text(context.attributes.contentTypeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    RecordingTimer(state: context.state)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(intent: StopRecordingIntent()) {
                    Image(systemName: "stop.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.red, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop and save recording")
            }
            .padding(16)
            .activityBackgroundTint(Color.black.opacity(0.92))
            .activitySystemActionForegroundColor(.white)
            .widgetURL(URL(string: "mediatools://record"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Recording", systemImage: "waveform")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RecordingTimer(state: context.state)
                        .font(.caption.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.attributes.contentTypeLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(intent: StopRecordingIntent()) {
                            Label("Stop & Save", systemImage: "stop.fill")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.isInterrupted ? "pause.fill" : "waveform")
                    .foregroundStyle(.red)
            } compactTrailing: {
                RecordingTimer(state: context.state)
                    .font(.caption2.monospacedDigit())
                    .frame(maxWidth: 46)
            } minimal: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
            }
            .widgetURL(URL(string: "mediatools://record"))
            .keylineTint(.red)
        }
    }
}

private struct RecordingTimer: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        if let resumedAt = state.resumedAt {
            Text(
                timerInterval: resumedAt.addingTimeInterval(-state.elapsedDuration)...Date.distantFuture,
                countsDown: false
            )
        } else {
            Text(Self.format(state.elapsedDuration))
        }
    }

    private static func format(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded(.down)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}
