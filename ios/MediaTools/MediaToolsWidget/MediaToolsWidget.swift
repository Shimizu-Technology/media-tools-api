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
            VStack(alignment: .leading, spacing: 6) {
                Text("Media Tools")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)

                Spacer(minLength: 0)

                Button(intent: QuickRecordIntent()) {
                    Label("Record", systemImage: "mic")
                        .font(.headline)
                        .foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Theme.accentFill, in: Capsule())
                }
                .buttonStyle(.plain)

                Text("Tap again to stop.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
            .containerBackground(Theme.bg, for: .widget)
        }
        .configurationDisplayName("Quick Record")
        .description("Open Media Tools to start recording, then stop from the Live Activity.")
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
            .tint(Theme.accentFill)
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
                Image(systemName: activityIcon(for: context.state))
                    .font(.headline)
                    .foregroundStyle(activityColor(for: context.state))
                    .frame(width: 24)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(activityTitle(for: context.state))
                        .font(.system(.headline, design: .serif, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(context.attributes.contentTypeLabel)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    RecordingTimer(state: context.state)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    if !context.state.isInterrupted {
                        if context.state.isPaused {
                            Button(intent: ResumeRecordingIntent()) {
                                Image(systemName: "play.fill")
                                    .font(.headline)
                                    .foregroundStyle(Theme.text)
                                    .frame(width: 44, height: 44)
                                    .background(Theme.fill, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Resume recording")
                        } else {
                            Button(intent: PauseRecordingIntent()) {
                                Image(systemName: "pause.fill")
                                    .font(.headline)
                                    .foregroundStyle(Theme.text)
                                    .frame(width: 44, height: 44)
                                    .background(Theme.fill, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Pause recording")
                        }
                    }

                    Button(intent: StopRecordingIntent()) {
                        Image(systemName: "stop.fill")
                            .font(.headline)
                            .foregroundStyle(Theme.onRecord)
                            .frame(width: 44, height: 44)
                            .background(Theme.record, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop and save recording")
                }
            }
            .padding(16)
            .activityBackgroundTint(Theme.bg)
            .activitySystemActionForegroundColor(Theme.text)
            .widgetURL(URL(string: "mediatools://record"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(activityTitle(for: context.state), systemImage: activityIcon(for: context.state))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(activityColor(for: context.state))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RecordingTimer(state: context.state)
                        .font(.caption.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        Text(context.attributes.contentTypeLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !context.state.isInterrupted {
                            if context.state.isPaused {
                                Button(intent: ResumeRecordingIntent()) {
                                    Label("Resume", systemImage: "play.fill")
                                        .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.bordered)
                                .tint(Theme.text)
                            } else {
                                Button(intent: PauseRecordingIntent()) {
                                    Label("Pause", systemImage: "pause.fill")
                                        .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.bordered)
                                .tint(Theme.text)
                            }
                        }
                        Button(intent: StopRecordingIntent()) {
                            Label("Stop & Save", systemImage: "stop.fill")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.record)
                    }
                }
            } compactLeading: {
                Image(systemName: activityIcon(for: context.state))
                    .foregroundStyle(activityColor(for: context.state))
            } compactTrailing: {
                RecordingTimer(state: context.state)
                    .font(.caption2.monospacedDigit())
                    .frame(maxWidth: 46)
            } minimal: {
                Image(systemName: activityIcon(for: context.state))
                    .foregroundStyle(activityColor(for: context.state))
            }
            .widgetURL(URL(string: "mediatools://record"))
            .keylineTint(Theme.record)
        }
    }

    private func activityTitle(for state: RecordingActivityAttributes.ContentState) -> String {
        if state.isInterrupted { return "Recording interrupted" }
        if state.isPaused { return "Recording paused" }
        return "Recording"
    }

    private func activityIcon(for state: RecordingActivityAttributes.ContentState) -> String {
        if state.isInterrupted { return "exclamationmark.waveform" }
        if state.isPaused { return "pause.fill" }
        return "record.circle"
    }

    private func activityColor(for state: RecordingActivityAttributes.ContentState) -> Color {
        // Red only while audio is actually being captured.
        state.isInterrupted || state.isPaused ? Theme.text : Theme.record
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
