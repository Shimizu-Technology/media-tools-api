import Foundation
import WidgetKit

/// Updates shared UserDefaults so the widget can display recent items.
enum WidgetService {
    private static let suiteName = Configuration.appGroupIdentifier
    private static let key = "recent_items"

    /// Update widget data with current library state.
    static func updateRecentItems(
        transcripts: [Transcript],
        audioItems: [AudioTranscription],
        pdfItems: [PDFExtraction]
    ) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }

        // Combine all items, sort by date (newest first), take top 5
        struct WidgetItem: Codable {
            let title: String
            let type: String
            let status: String
        }

        var items: [(date: Date?, item: WidgetItem)] = []

        for t in transcripts {
            items.append((t.createdAt, WidgetItem(title: t.displayTitle, type: "video", status: t.status)))
        }
        for a in audioItems {
            items.append((a.createdAt, WidgetItem(title: a.displayTitle, type: "audio", status: a.status)))
        }
        for p in pdfItems {
            items.append((p.createdAt, WidgetItem(title: p.displayTitle, type: "pdf", status: p.status)))
        }

        // Sort newest first, nil dates at end
        items.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }

        let top5 = items.prefix(5).map(\.item)

        if let data = try? JSONEncoder().encode(top5) {
            defaults.set(data, forKey: key)
        }

        // Tell WidgetKit to refresh
        WidgetCenter.shared.reloadTimelines(ofKind: "MediaToolsWidget")
    }
}
