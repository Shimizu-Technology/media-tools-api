import Foundation

/// The Library reads like a dated notebook: items under Today, Yesterday, then
/// the date. Consecutive runs group, so "Oldest first" works without reordering.
struct LibraryDaySection: Identifiable, Equatable {
    let title: String
    let items: [LibraryListItem]

    var id: String { items.first?.reference.id ?? title }

    static func group(
        _ items: [LibraryListItem],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [LibraryDaySection] {
        var sections: [LibraryDaySection] = []
        var run: [LibraryListItem] = []
        var runTitle: String?

        for item in items {
            let title = dayTitle(for: item.createdAt, now: now, calendar: calendar)
            if title != runTitle, let runTitle, !run.isEmpty {
                sections.append(LibraryDaySection(title: runTitle, items: run))
                run = []
            }
            runTitle = title
            run.append(item)
        }
        if let runTitle, !run.isEmpty {
            sections.append(LibraryDaySection(title: runTitle, items: run))
        }
        return sections
    }

    static func dayTitle(for date: Date?, now: Date, calendar: Calendar) -> String {
        guard let date else { return "Earlier" }
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        var format = Date.FormatStyle(date: .omitted, time: .omitted)
            .weekday(.wide)
            .month(.abbreviated)
            .day()
        format.timeZone = calendar.timeZone
        if !sameYear { format = format.year() }
        return date.formatted(format)
    }
}
