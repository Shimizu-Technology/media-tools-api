import SwiftUI
import WidgetKit

/// Watch face complication showing last transcription status.
/// Uses WidgetKit (available on watchOS 9+).
struct MediaToolsComplication: Widget {
    let kind = "MediaToolsComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ComplicationProvider()) { entry in
            ComplicationView(entry: entry)
        }
        .configurationDisplayName("Media Tools")
        .description("Quick access to record and see transcription status.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
            .accessoryCorner,
        ])
    }
}

// MARK: - Provider

struct ComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> ComplicationEntry {
        ComplicationEntry(date: Date(), lastTitle: "Ready to record", isProcessing: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (ComplicationEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ComplicationEntry>) -> Void) {
        let entry = ComplicationEntry(
            date: Date(),
            lastTitle: UserDefaults.standard.string(forKey: "lastTranscriptionTitle") ?? "Ready",
            isProcessing: UserDefaults.standard.bool(forKey: "isTranscribing")
        )
        let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(300)))
        completion(timeline)
    }
}

// MARK: - Entry

struct ComplicationEntry: TimelineEntry {
    let date: Date
    let lastTitle: String
    let isProcessing: Bool
}

// MARK: - Views

struct ComplicationView: View {
    let entry: ComplicationEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            circularView
        case .accessoryRectangular:
            rectangularView
        case .accessoryInline:
            inlineView
        case .accessoryCorner:
            cornerView
        default:
            circularView
        }
    }

    private var circularView: some View {
        ZStack {
            AccessoryWidgetBackground()
            if entry.isProcessing {
                ProgressView()
            } else {
                Image(systemName: "mic.fill")
                    .font(.title3)
            }
        }
    }

    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: entry.isProcessing ? "waveform" : "mic.fill")
                    .font(.caption2)
                Text("Media Tools")
                    .font(.caption2.weight(.semibold))
            }
            Text(entry.lastTitle)
                .font(.caption)
                .lineLimit(1)
        }
    }

    private var inlineView: some View {
        HStack {
            Image(systemName: "mic.fill")
            Text(entry.isProcessing ? "Transcribing..." : entry.lastTitle)
        }
    }

    private var cornerView: some View {
        Image(systemName: "mic.fill")
            .font(.title3)
            .widgetLabel {
                Text(entry.isProcessing ? "Recording..." : "Record")
            }
    }
}
