import UIKit
import XCTest
@testable import MediaTools

final class LedgerDesignTests: XCTestCase {
    /// A typo in a color name draws nothing at all, in one appearance or both.
    func testEveryTokenResolvesInBothAppearances() throws {
        let names = [
            "bg", "surface", "text", "text-secondary", "separator", "accent", "accent-fill",
            "on-accent", "record", "on-record", "danger", "on-danger", "fill", "accent-tint",
        ]
        for name in names {
            let color = try XCTUnwrap(UIColor(named: "Ledger/\(name)"), name)
            XCTAssertNotNil(color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)), name)
            XCTAssertNotNil(color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)), name)
        }
    }

    func testPaperAndGraphiteMatchTheSharedTokens() throws {
        let bg = try XCTUnwrap(UIColor(named: "Ledger/bg"))
        XCTAssertEqual(hex(bg, style: .light), "F7F5F0")
        XCTAssertEqual(hex(bg, style: .dark), "191714")
        let record = try XCTUnwrap(UIColor(named: "Ledger/record"))
        XCTAssertEqual(hex(record, style: .light), "C2372C")
        XCTAssertEqual(hex(record, style: .dark), "F0625A")
    }

    func testDurationsSwitchToMinutesOnceSecondsStopMattering() {
        XCTAssertNil(LedgerFormat.duration(0))
        XCTAssertNil(LedgerFormat.duration(.nan))
        XCTAssertEqual(LedgerFormat.duration(31), "0:31")
        XCTAssertEqual(LedgerFormat.duration(108), "1:48")
        XCTAssertEqual(LedgerFormat.duration(599), "9:59")
        XCTAssertEqual(LedgerFormat.duration(600), "10 min")
        XCTAssertEqual(LedgerFormat.duration(2_530), "42 min")
        XCTAssertEqual(LedgerFormat.duration(3_600), "1 hr")
        XCTAssertEqual(LedgerFormat.duration(3_900), "1 hr 5 min")
    }

    func testOnlyUnfinishedItemsShowAStatus() {
        XCTAssertNil(ItemAttention(status: "completed"))
        XCTAssertEqual(ItemAttention(status: "processing")?.isWorking, true)
        XCTAssertEqual(ItemAttention(status: "pending")?.isWorking, true)
        XCTAssertEqual(ItemAttention(status: "failed")?.isWorking, false)
    }

    func testTheLibraryGroupsByDayInEitherSortOrder() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 12)))
        func item(_ id: String, hoursAgo: Double) -> LibraryListItem {
            LibraryListItem(
                id: id, itemType: "audio", title: id, subtitle: "", status: "completed",
                wordCount: 0, duration: 0, pageCount: 0, summaryStatus: "", favorite: false,
                archived: false, tags: [], createdAt: now.addingTimeInterval(-hoursAgo * 3_600)
            )
        }
        let newestFirst = [
            item("a", hoursAgo: 1),
            item("b", hoursAgo: 2),
            item("c", hoursAgo: 20),
            item("d", hoursAgo: 60),
        ]

        let sections = LibraryDaySection.group(newestFirst, now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.items.count), [2, 1, 1])
        XCTAssertEqual(sections[0].title, "Today")
        XCTAssertEqual(sections[1].title, "Yesterday")
        XCTAssertFalse(["Today", "Yesterday"].contains(sections[2].title))

        let oldestFirst = LibraryDaySection.group(newestFirst.reversed(), now: now, calendar: calendar)
        XCTAssertEqual(oldestFirst.last?.title, "Today")
        XCTAssertEqual(oldestFirst.map(\.items.count), [1, 1, 2])
    }

    func testAnItemWithNoDateStillAppears() {
        let item = LibraryListItem(
            id: "x", itemType: "pdf", title: "x", subtitle: "", status: "completed",
            wordCount: 0, duration: 0, pageCount: 0, summaryStatus: "", favorite: false,
            archived: false, tags: [], createdAt: nil
        )
        XCTAssertEqual(LibraryDaySection.group([item]).first?.title, "Earlier")
    }

    private func hex(_ color: UIColor, style: UIUserInterfaceStyle) -> String {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(format: "%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
}
