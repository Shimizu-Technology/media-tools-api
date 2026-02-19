import WidgetKit
import SwiftUI

// MARK: - Timeline Provider

struct RecentItemsProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecentItemsEntry {
        RecentItemsEntry(date: Date(), items: [
            .init(title: "TED Talk: How to stay calm", type: "video", status: "completed"),
            .init(title: "Team Meeting Notes", type: "audio", status: "completed"),
            .init(title: "Project Spec v2.pdf", type: "pdf", status: "completed"),
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (RecentItemsEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentItemsEntry>) -> Void) {
        // Read from shared UserDefaults (app group)
        let items = loadRecentItems()
        let entry = RecentItemsEntry(date: Date(), items: items)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    private func loadRecentItems() -> [WidgetItem] {
        guard let defaults = UserDefaults(suiteName: "group.com.shimizu-technology.media-tools"),
              let data = defaults.data(forKey: "recent_items"),
              let items = try? JSONDecoder().decode([WidgetItem].self, from: data) else {
            return []
        }
        return Array(items.prefix(5))
    }
}

// MARK: - Entry

struct RecentItemsEntry: TimelineEntry {
    let date: Date
    let items: [WidgetItem]
}

struct WidgetItem: Codable, Identifiable {
    var id: String { title + type }
    let title: String
    let type: String // video, audio, pdf
    let status: String

    var icon: String {
        switch type {
        case "video": "play.rectangle.fill"
        case "audio": "mic.fill"
        case "pdf": "doc.fill"
        default: "doc"
        }
    }

    var iconColor: Color {
        switch type {
        case "video": .teal
        case "audio": .orange
        case "pdf": .red
        default: .gray
        }
    }
}

// MARK: - Widget Views

struct MediaToolsWidgetEntryView: View {
    var entry: RecentItemsProvider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            smallWidget
        case .systemMedium:
            mediumWidget
        default:
            mediumWidget
        }
    }

    private var smallWidget: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "waveform.circle.fill")
                    .foregroundStyle(.teal)
                Text("Media Tools")
                    .font(.caption.weight(.semibold))
            }

            if entry.items.isEmpty {
                Text("No recent items")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entry.items.prefix(3)) { item in
                    HStack(spacing: 6) {
                        Image(systemName: item.icon)
                            .font(.caption2)
                            .foregroundStyle(item.iconColor)
                        Text(item.title)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()
        }
        .padding(12)
    }

    private var mediumWidget: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "waveform.circle.fill")
                    .foregroundStyle(.teal)
                Text("Recent Items")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            if entry.items.isEmpty {
                Text("No recent transcriptions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            } else {
                ForEach(entry.items.prefix(4)) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.icon)
                            .font(.caption)
                            .foregroundStyle(item.iconColor)
                            .frame(width: 16)

                        Text(item.title)
                            .font(.caption)
                            .lineLimit(1)

                        Spacer()

                        if item.status == "processing" || item.status == "pending" {
                            Image(systemName: "clock")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(12)
    }
}

// MARK: - Widget Declaration

struct MediaToolsWidget: Widget {
    let kind: String = "MediaToolsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RecentItemsProvider()) { entry in
            MediaToolsWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Media Tools")
        .description("See your recent transcriptions at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Widget Bundle

@main
struct MediaToolsWidgetBundle: WidgetBundle {
    var body: some Widget {
        MediaToolsWidget
    }
}

// MARK: - Previews

#Preview(as: .systemSmall) {
    MediaToolsWidget()
} timeline: {
    RecentItemsEntry(date: .now, items: [
        .init(title: "TED Talk: How to stay calm", type: "video", status: "completed"),
        .init(title: "Team standup 2/19", type: "audio", status: "completed"),
        .init(title: "Contract_v3.pdf", type: "pdf", status: "processing"),
    ])
}

#Preview(as: .systemMedium) {
    MediaToolsWidget()
} timeline: {
    RecentItemsEntry(date: .now, items: [
        .init(title: "TED Talk: How to stay calm when you know you'll be stressed", type: "video", status: "completed"),
        .init(title: "Team standup 2/19", type: "audio", status: "completed"),
        .init(title: "Contract_v3.pdf", type: "pdf", status: "processing"),
        .init(title: "Rick Astley - Never Gonna Give You Up", type: "video", status: "completed"),
    ])
}
