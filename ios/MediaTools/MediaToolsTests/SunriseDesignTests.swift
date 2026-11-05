import CoreGraphics
import UIKit
import XCTest
@testable import MediaTools

final class SunriseDesignTests: XCTestCase {
    private static let tokens = [
        "background", "surface", "surface-2", "text", "text-secondary", "separator",
        "accent-fill", "on-accent", "accent-text", "tab-bar", "warning", "warning-surface",
        "waveform-start", "waveform-end", "waveform-unplayed", "danger", "on-danger",
    ]

    /// A typo in a color name draws nothing at all, in one appearance or both.
    func testEveryTokenResolvesInBothAppearances() throws {
        for name in Self.tokens {
            let color = try XCTUnwrap(UIColor(named: "Sunrise/\(name)"), name)
            XCTAssertNotNil(color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)), name)
            XCTAssertNotNil(color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)), name)
        }
    }

    func testTokensMatchTheDesignPlan() throws {
        let expected: [(String, String, String)] = [
            ("background", "FFF7EF", "15110F"),
            ("surface", "FFFFFF", "231C18"),
            ("surface-2", "F6E9DD", "30271F"),
            ("text", "2A1A13", "FBF0E7"),
            ("text-secondary", "6E5B50", "B9A99C"),
            ("separator", "F0E2D5", "2F2620"),
            ("accent-fill", "C9441E", "FF8F5E"),
            ("on-accent", "FFFFFF", "2A1209"),
            ("accent-text", "BB3B18", "FF9B6E"),
            ("tab-bar", "FFFBF7", "1B1613"),
            ("warning", "A35300", "FFB65C"),
            ("warning-surface", "FFEBD0", "38280F"),
            ("waveform-start", "E8892B", "FFB347"),
            ("waveform-end", "C2401B", "FF6B4A"),
            ("waveform-unplayed", "E5D5C7", "4A3D33"),
        ]
        for (name, light, dark) in expected {
            let color = try XCTUnwrap(UIColor(named: "Sunrise/\(name)"), name)
            XCTAssertEqual(hex(color, style: .light), light, name)
            XCTAssertEqual(hex(color, style: .dark), dark, name)
        }
    }

    /// Text and icon pairs the app actually draws, in both appearances.
    func testTextPairsClearAA() throws {
        let surfaces = ["background", "surface", "surface-2", "warning-surface", "tab-bar"]
        for style in [UIUserInterfaceStyle.light, .dark] {
            for text in ["text", "text-secondary", "accent-text", "warning", "danger"] {
                for surface in surfaces {
                    let ratio = try contrast(text, surface, style: style)
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(text) on \(surface), \(style.rawValue)")
                }
            }
            XCTAssertGreaterThanOrEqual(try contrast("on-accent", "accent-fill", style: style), 4.5)
            XCTAssertGreaterThanOrEqual(try contrast("on-danger", "danger", style: style), 4.5)
        }
    }

    func testWhiteOnEveryHeroStopClearsAA() {
        func luminance(_ hex: String) -> CGFloat {
            let value = Int(hex, radix: 16) ?? 0
            func linear(_ channel: Int) -> CGFloat {
                let scaled = CGFloat(channel) / 255
                return scaled <= 0.03928 ? scaled / 12.92 : pow((scaled + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear((value >> 16) & 0xFF) + 0.7152 * linear((value >> 8) & 0xFF) + 0.0722 * linear(value & 0xFF)
        }
        for hex in Theme.heroStopHexes {
            XCTAssertGreaterThanOrEqual(1.05 / (luminance(hex) + 0.05), 4.5, hex)
        }
    }

    func testDestructiveRedStaysDistinctFromTheAccent() throws {
        let danger = try XCTUnwrap(UIColor(named: "Sunrise/danger"))
        let accent = try XCTUnwrap(UIColor(named: "Sunrise/accent-fill"))
        for style in [UIUserInterfaceStyle.light, .dark] {
            XCTAssertNotEqual(hex(danger, style: style), hex(accent, style: style))
        }
    }

    func testCollectionColorsFallBackToCoral() {
        XCTAssertEqual(CollectionColor(key: "teal"), .teal)
        XCTAssertEqual(CollectionColor(key: nil), .coral)
        XCTAssertEqual(CollectionColor(key: "chartreuse"), .coral)
        XCTAssertEqual(CollectionColor.allCases.map(\.rawValue), ["coral", "teal", "violet", "amber", "blue", "rose"])
    }

    func testDurationsReadLikeAnAudioPlayer() {
        XCTAssertNil(MediaFormat.duration(0))
        XCTAssertNil(MediaFormat.duration(.nan))
        XCTAssertEqual(MediaFormat.duration(31), "0:31")
        XCTAssertEqual(MediaFormat.duration(516), "8:36")
        XCTAssertEqual(MediaFormat.duration(2_530), "42:10")
        XCTAssertEqual(MediaFormat.duration(5_352), "1:29:12")
    }

    func testOnlyUnfinishedItemsShowAStatus() {
        XCTAssertNil(ItemAttention(status: "completed"))
        XCTAssertEqual(ItemAttention(status: "processing")?.isWorking, true)
        XCTAssertEqual(ItemAttention(status: "pending")?.isWorking, true)
        XCTAssertEqual(ItemAttention(status: "failed")?.isWorking, false)
    }

    func testRowDatesGoFromTimeToDayToYear() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 12)))
        XCTAssertNil(MediaFormat.rowDate(nil, now: now, calendar: calendar))

        let today = MediaFormat.rowDate(now.addingTimeInterval(-3_600), now: now, calendar: calendar)
        XCTAssertEqual(today?.contains("11"), true, "Today shows the time")

        XCTAssertEqual(
            MediaFormat.rowDate(now.addingTimeInterval(-20 * 3_600), now: now, calendar: calendar),
            "Yesterday"
        )
        let thisYear = MediaFormat.rowDate(now.addingTimeInterval(-60 * 3_600), now: now, calendar: calendar)
        XCTAssertEqual(thisYear?.contains("Nov"), true)
        XCTAssertEqual(thisYear?.contains("2026"), false)
        let lastYear = MediaFormat.rowDate(now.addingTimeInterval(-400 * 24 * 3_600), now: now, calendar: calendar)
        XCTAssertEqual(lastYear?.contains("2025"), true)
    }

    func testGreetingFollowsTheTimeOfDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        func greeting(hour: Int) throws -> String {
            let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: hour)))
            return HomeGreeting.text(for: date, calendar: calendar)
        }
        XCTAssertEqual(try greeting(hour: 7), "Good morning")
        XCTAssertEqual(try greeting(hour: 11), "Good morning")
        XCTAssertEqual(try greeting(hour: 12), "Good afternoon")
        XCTAssertEqual(try greeting(hour: 16), "Good afternoon")
        XCTAssertEqual(try greeting(hour: 17), "Good evening")
        XCTAssertEqual(try greeting(hour: 2), "Good evening")
    }

    private func contrast(_ first: String, _ second: String, style: UIUserInterfaceStyle) throws -> CGFloat {
        let a = luminance(try XCTUnwrap(UIColor(named: "Sunrise/\(first)"), first), style: style)
        let b = luminance(try XCTUnwrap(UIColor(named: "Sunrise/\(second)"), second), style: style)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func luminance(_ color: UIColor, style: UIUserInterfaceStyle) -> CGFloat {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    private func hex(_ color: UIColor, style: UIUserInterfaceStyle) -> String {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(format: "%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
}

final class WaveformDisplayTests: XCTestCase {
    func testNoDataMeansNoBars() {
        XCTAssertFalse(WaveformDisplay.hasData(nil))
        XCTAssertFalse(WaveformDisplay.hasData([]))
        XCTAssertTrue(WaveformDisplay.hasData([0, 0, 0]), "Silence is real audio data")
        XCTAssertEqual(WaveformDisplay.levels(from: [], barCount: 10), [])
        XCTAssertEqual(WaveformDisplay.levels(from: [50], barCount: 0), [])
    }

    func testBarCountFitsTheWidth() {
        XCTAssertEqual(WaveformDisplay.barCount(width: 64, barWidth: 2, spacing: 1.5), 18)
        XCTAssertEqual(WaveformDisplay.barCount(width: 2, barWidth: 2, spacing: 1.5), 1)
        XCTAssertEqual(WaveformDisplay.barCount(width: 1, barWidth: 2, spacing: 1.5), 0)
        XCTAssertEqual(WaveformDisplay.barCount(width: .infinity, barWidth: 2, spacing: 1.5), 0)
    }

    func testShrinkingKeepsEachBucketsLoudestPeak() {
        let peaks = [0, 10, 0, 100, 0, 0, 50, 0]
        XCTAssertEqual(WaveformDisplay.levels(from: peaks, barCount: 4), [0.1, 1, 0, 0.5])
    }

    func testStretchingRepeatsPeaksWithoutInventingAny() {
        let levels = WaveformDisplay.levels(from: [10, 90], barCount: 4)
        XCTAssertEqual(levels, [0.1, 0.1, 0.9, 0.9])
    }

    func testEveryBarIsAccountedForAtTheServersLengths() {
        let row = Array(repeating: 40, count: 32)
        let player = Array(repeating: 40, count: 200)
        for barCount in [1, 7, 18, 32, 62, 200, 300] {
            XCTAssertEqual(WaveformDisplay.levels(from: row, barCount: barCount).count, barCount)
            XCTAssertEqual(WaveformDisplay.levels(from: player, barCount: barCount).count, barCount)
        }
    }

    func testValuesOutsideTheContractAreClamped() {
        XCTAssertEqual(WaveformDisplay.levels(from: [-20, 250], barCount: 2), [0, 1])
    }

    func testATouchMapsToAFractionOfTheTrack() {
        XCTAssertEqual(WaveformDisplay.fraction(atX: 50, width: 200), 0.25)
        XCTAssertEqual(WaveformDisplay.fraction(atX: -5, width: 200), 0)
        XCTAssertEqual(WaveformDisplay.fraction(atX: 500, width: 200), 1)
        XCTAssertEqual(WaveformDisplay.fraction(atX: 5, width: 0), 0)
    }

    func testTheLiveMeterUsesADecibelScaleSoSpeechIsVisible() {
        XCTAssertEqual(LiveLevelMeter.displayLevel(linearLevel: 0), 0)
        XCTAssertEqual(LiveLevelMeter.displayLevel(linearLevel: 1), 1)
        // -30 dB, ordinary speech, sits well clear of the floor.
        XCTAssertEqual(LiveLevelMeter.displayLevel(linearLevel: 0.0316), 0.4, accuracy: 0.01)
        XCTAssertEqual(LiveLevelMeter.displayLevel(linearLevel: 0.0001), 0, "Below the floor")
        XCTAssertEqual(LiveLevelMeter.displayLevel(linearLevel: .nan), 0)
        XCTAssertEqual(LiveLevelMeter.displayLevel(linearLevel: 4), 1)
    }

    func testTheLiveMeterKeepsOnlyRecentReadings() {
        var meter = LiveLevelMeter()
        XCTAssertTrue(meter.levels.isEmpty, "No reading, no bars")
        for _ in 0..<(LiveLevelMeter.capacity + 5) {
            meter.append(linearLevel: 0.1)
        }
        meter.append(linearLevel: 1)
        XCTAssertEqual(meter.levels.count, LiveLevelMeter.capacity)
        XCTAssertEqual(meter.levels.last, 1, "Newest last")
    }

    func testTheActiveSegmentFollowsPlaybackTime() {
        func segment(_ ordinal: Int, start: Int64?) -> MediaSegment {
            MediaSegment(
                id: "s\(ordinal)", itemType: "audio", itemId: "a", ordinal: ordinal,
                startMs: start, endMs: nil, pageNumber: nil, text: "", createdAt: nil
            )
        }
        let segments = [segment(0, start: 0), segment(1, start: 12_000), segment(2, start: 31_000)]
        XCTAssertEqual(segments.activeSegmentIndex(at: 0), 0)
        XCTAssertEqual(segments.activeSegmentIndex(at: 11.9), 0)
        XCTAssertEqual(segments.activeSegmentIndex(at: 12), 1)
        XCTAssertEqual(segments.activeSegmentIndex(at: 500), 2)
        XCTAssertNil(segments.activeSegmentIndex(at: .nan))
        XCTAssertNil([MediaSegment]().activeSegmentIndex(at: 5))
        XCTAssertNil([segment(0, start: nil)].activeSegmentIndex(at: 5), "PDF pages have no times")
        let late = [segment(0, start: 5_000)]
        XCTAssertNil(late.activeSegmentIndex(at: 1), "Nothing is playing yet")
    }
}

final class NeedsYouSelectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func recording(
        _ state: LocalRecordingState,
        autoTranscribe: Bool? = nil,
        remoteID: String? = nil,
        duration: TimeInterval = 5_352,
        createdAt: Date? = nil,
        originalFilename: String? = nil
    ) -> LocalRecording {
        LocalRecording(
            id: UUID(), filename: "a.caf", originalFilename: originalFilename,
            createdAt: createdAt ?? now.addingTimeInterval(-3_600), duration: duration,
            contentType: "general", state: state, remoteTranscriptionID: remoteID,
            autoTranscribeRequested: autoTranscribe
        )
    }

    private func row(_ id: String, status: String = "failed", hoursAgo: Double, archived: Bool = false) -> LibraryListItem {
        LibraryListItem(
            id: id, itemType: "audio", title: id, subtitle: "", status: status,
            wordCount: 0, duration: 0, pageCount: 0, summaryStatus: "", favorite: false,
            archived: archived, tags: [], createdAt: now.addingTimeInterval(-hoursAgo * 3_600)
        )
    }

    private func select(
        recordings: [LocalRecording] = [],
        failures: [LibraryListItem] = [],
        willSend: Bool = true
    ) -> [NeedsYouItem] {
        NeedsYouSelection.select(
            recordings: recordings, shares: [], serverFailures: failures,
            autoTranscribeWillSend: willSend, now: now
        )
    }

    /// The two recordings on Leon's phone: never flagged for auto-transcribe, and one
    /// that did not finish saving. Both must have something to do.
    func testAnInterruptedAndAnInvalidRecordingBothNeedAPerson() {
        let interrupted = recording(.interrupted)
        let invalid = recording(.invalid)
        XCTAssertEqual(select(recordings: [interrupted, invalid]).count, 2)
        XCTAssertEqual(interrupted.needsYouAction, .transcribe)
        XCTAssertEqual(invalid.needsYouAction, .options)
    }

    func testARecordingOnItsWayNeedsNobody() {
        for state in [LocalRecordingState.recording, .waitingForUpload, .uploading, .finalizingUpload, .serverProcessing] {
            XCTAssertTrue(select(recordings: [recording(state)]).isEmpty, "\(state)")
        }
    }

    func testAnAutomaticRecordingOnlyNeedsAPersonWhenNothingWillSendIt() {
        let waiting = recording(.ready, autoTranscribe: true)
        XCTAssertTrue(select(recordings: [waiting], willSend: true).isEmpty)
        XCTAssertEqual(select(recordings: [waiting], willSend: false).count, 1)
        XCTAssertEqual(select(recordings: [recording(.ready, autoTranscribe: nil)], willSend: true).count, 1)
    }

    func testServerFailuresCountForSevenDaysThenStayInTheLibrary() {
        let items = select(failures: [
            row("recent", hoursAgo: 24),
            row("edge", hoursAgo: 7 * 24 - 1),
            row("old", hoursAgo: 7 * 24 + 1),
            row("done", status: "completed", hoursAgo: 1),
            row("archived", hoursAgo: 1, archived: true),
        ])
        XCTAssertEqual(items.map(\.id), ["server:audio:recent", "server:audio:edge"])
    }

    func testADeviceCopyAndItsServerFailureShowOnce() {
        let items = select(
            recordings: [recording(.uploadFailed, remoteID: "same")],
            failures: [row("same", hoursAgo: 1)]
        )
        XCTAssertEqual(items.count, 1)
        guard case .recording = items[0] else { return XCTFail("The device copy has more to offer") }
    }

    func testOnDeviceWorkComesFirstNewestFirst() {
        let older = recording(.invalid, createdAt: now.addingTimeInterval(-90_000))
        let newer = recording(.interrupted, createdAt: now.addingTimeInterval(-10))
        let items = select(recordings: [older, newer], failures: [row("server", hoursAgo: 0.1)])
        XCTAssertEqual(items.map(\.id), [
            "recording:\(newer.id.uuidString)",
            "recording:\(older.id.uuidString)",
            "server:audio:server",
        ])
    }

    func testTheSectionCanBeEmpty() {
        XCTAssertTrue(select().isEmpty)
    }

    func testRowsSayWhatHappenedAndHowLong() {
        XCTAssertEqual(recording(.interrupted).needsYouDetail, "1:29:12, not sent yet")
        XCTAssertEqual(recording(.invalid, duration: 1_705).needsYouDetail, "28:25, did not save fully")
        XCTAssertEqual(recording(.invalid, remoteID: "x", duration: 1_705).needsYouDetail, "28:25, could not be read")
        XCTAssertEqual(recording(.uploadFailed, duration: 60).needsYouDetail, "1:00, upload paused")
        XCTAssertEqual(recording(.invalid, duration: 0).needsYouDetail, "Did not save fully", "An unknown length is left out")
    }

    func testImportedFilesKeepTheirNames() {
        XCTAssertEqual(recording(.ready, originalFilename: "Call v2.1.m4a").needsYouTitle, "Call v2.1")
        XCTAssertTrue(recording(.interrupted).needsYouTitle.hasSuffix(" recording"))
    }

    func testRecheckingAnInvalidRecordingNeverLosesIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try MainActor.assumeIsolated {
            let store = try RecordingStore(rootDirectory: directory)
            let recording = LocalRecording(
                id: UUID(), filename: "broken.m4a", originalFilename: nil, createdAt: self.now,
                duration: 10, contentType: "general", state: .invalid, lastError: "Unfinalized"
            )
            let noMoov = Data([0, 0, 0, 16]) + Data("mdat".utf8) + Data(count: 8)
            try noMoov.write(to: store.fileURL(for: recording))
            try store.saveRecordings([recording])

            let coordinator = RecordingCoordinator(
                store: store, simulatesCapture: true,
                localAccountDefaults: UserDefaults(suiteName: UUID().uuidString)!
            )
            guard case .failure = coordinator.recheckInvalidRecording(recording.id) else {
                return XCTFail("A file with no index must not pass")
            }
            XCTAssertEqual(coordinator.recording(withID: recording.id)?.state, .invalid)
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: recording).path))

            // A file that turns out to be readable can be sent.
            try Self.minimalCAF.write(to: store.fileURL(for: recording), options: .atomic)
            let renamed = LocalRecording(
                id: UUID(), filename: "fine.caf", originalFilename: nil, createdAt: self.now,
                duration: 10, contentType: "general", state: .invalid, lastError: "Rejected"
            )
            try Self.minimalCAF.write(to: store.fileURL(for: renamed))
            try store.saveRecordings([renamed])
            let second = RecordingCoordinator(
                store: store, simulatesCapture: true,
                localAccountDefaults: UserDefaults(suiteName: UUID().uuidString)!
            )
            guard case .success(let passed) = second.recheckInvalidRecording(renamed.id) else {
                return XCTFail("A readable file should pass")
            }
            XCTAssertEqual(passed.state, .ready)
            XCTAssertNil(passed.lastError)
            XCTAssertTrue(passed.canUpload)
        }
    }

    private static var minimalCAF: Data {
        func chunk(_ type: String, _ payload: Data) -> Data {
            var data = Data(type.utf8)
            var size = UInt64(payload.count).bigEndian
            withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
            return data + payload
        }
        return Data("caff".utf8) + Data([0, 1, 0, 0])
            + chunk("desc", Data(count: 32))
            + chunk("data", Data(count: 64))
    }
}

final class NewLibraryFieldDecodingTests: XCTestCase {
    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private let baseRow = """
        "id": "a", "item_type": "audio", "title": "T", "subtitle": "", "status": "completed",
        "word_count": 1, "duration": 516, "page_count": 0, "summary_status": "",
        "favorite": false, "archived": false, "tags": []
        """

    func testARowFromAServerWithoutTheNewFieldsStillDecodes() throws {
        let item = try decoder().decode(LibraryListItem.self, from: Data("{\(baseRow)}".utf8))
        XCTAssertNil(item.excerpt)
        XCTAssertNil(item.waveform)
        XCTAssertNil(item.collections)
        XCTAssertNil(item.displayExcerpt)
        XCTAssertNil(item.primaryCollection)
    }

    func testARowWithTheNewFieldsDecodes() throws {
        let json = """
            {\(baseRow), "excerpt": "What changed", "waveform": [0, 12, 40],
             "collections": [{"id": "c", "name": "Baby", "color": "coral"}, {"id": "d", "name": "Work"}]}
            """
        let item = try decoder().decode(LibraryListItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.displayExcerpt, "What changed")
        XCTAssertEqual(item.waveform, [0, 12, 40])
        XCTAssertEqual(item.primaryCollection?.name, "Baby")
        XCTAssertEqual(item.primaryCollection?.color, "coral")
        XCTAssertNil(item.collections?[1].color, "Color may be absent too")
    }

    func testEmptyAndNullValuesCollapse() throws {
        let json = #"{\#(baseRow), "excerpt": "   ", "waveform": null, "collections": []}"#
        let item = try decoder().decode(LibraryListItem.self, from: Data(json.utf8))
        XCTAssertNil(item.displayExcerpt)
        XCTAssertNil(item.primaryCollection)
        XCTAssertFalse(WaveformDisplay.hasData(item.waveform))
    }

    func testDetailAndCollectionsDecodeWithAndWithoutTheNewFields() throws {
        let withPeaks = #"{"id":"a","status":"completed","waveform":[1,2,3]}"#
        let without = #"{"id":"a","status":"completed"}"#
        XCTAssertEqual(try decoder().decode(AudioTranscription.self, from: Data(withPeaks.utf8)).waveform, [1, 2, 3])
        XCTAssertNil(try decoder().decode(AudioTranscription.self, from: Data(without.utf8)).waveform)

        let colored = #"{"id":"c","name":"Baby","color":"teal"}"#
        let plain = #"{"id":"c","name":"Baby"}"#
        XCTAssertEqual(try decoder().decode(Collection.self, from: Data(colored.utf8)).color, "teal")
        XCTAssertNil(try decoder().decode(Collection.self, from: Data(plain.utf8)).color)
    }

    func testRowDetailsDependOnTheType() {
        func row(type: String, duration: Double = 0, pages: Int = 0, words: Int = 0, subtitle: String = "") -> LibraryListItem {
            LibraryListItem(
                id: "a", itemType: type, title: "T", subtitle: subtitle, status: "completed",
                wordCount: words, duration: duration, pageCount: pages, summaryStatus: "",
                favorite: false, archived: false, tags: [], createdAt: nil
            )
        }
        XCTAssertEqual(row(type: "audio", duration: 516).trailingDetail, "8:36")
        XCTAssertEqual(row(type: "pdf", pages: 18).trailingDetail, "18p")
        XCTAssertNil(row(type: "pdf").trailingDetail)
        XCTAssertEqual(row(type: "youtube", words: 4_260).wordCountLabel, "4.3K words")
        XCTAssertNil(row(type: "audio", duration: 516, words: 900).wordCountLabel, "The length already says how much")
        XCTAssertEqual(row(type: "pdf").sourceLabel, "PDF")
        XCTAssertEqual(row(type: "youtube").sourceLabel, "Video")
        XCTAssertEqual(row(type: "youtube", subtitle: "YouTube").sourceLabel, "YouTube")
        XCTAssertNil(row(type: "audio", subtitle: "EN").sourceLabel)
    }

    func testTheStarredFilterAsksTheServer() {
        let path = MediaToolsService.libraryItemsPath(
            page: 1, perPage: 20, itemType: nil, status: nil, search: nil,
            sortDirection: "desc", favoriteOnly: true
        )
        XCTAssertTrue(path.contains("favorite=true"))
        XCTAssertFalse(MediaToolsService.libraryItemsPath(
            page: 1, perPage: 20, itemType: nil, status: nil, search: nil, sortDirection: "desc"
        ).contains("favorite"))
    }
}

@MainActor
final class LibraryChipTests: XCTestCase {
    func testChipsMapToTheServersFilters() {
        let model = LibraryViewModel(previewItems: [])
        XCTAssertEqual(model.selectedChip, .all)

        model.selectedChip = .recordings
        XCTAssertEqual(model.query.type, .audio)
        XCTAssertEqual(model.selectedChip, .recordings)

        model.selectedChip = .links
        XCTAssertEqual(model.query.type, .youtube)

        model.selectedChip = .pdfs
        XCTAssertEqual(model.query.type, .pdf)

        model.selectedChip = .starred
        XCTAssertTrue(model.query.favoriteOnly)
        XCTAssertEqual(model.query.type, .all)
        XCTAssertEqual(model.selectedChip, .starred)

        model.selectedChip = .archived
        XCTAssertTrue(model.query.archivedOnly)
        XCTAssertFalse(model.query.favoriteOnly)
        XCTAssertEqual(model.selectedChip, .archived)

        model.selectedChip = .all
        XCTAssertFalse(model.query.archivedOnly)
        XCTAssertEqual(model.query.type, .all)
    }

    func testAChipClearsAChosenCollection() {
        let model = LibraryViewModel(previewItems: [])
        model.selectedCollection = LibraryCollectionFilter(id: "c", name: "Baby")
        model.selectedChip = .recordings
        XCTAssertNil(model.selectedCollection)
    }

    func testStarredPreviewsFilter() async {
        let favorite = LibraryListItem(
            id: "star", itemType: "audio", title: "Star", subtitle: "", status: "completed",
            wordCount: 0, duration: 0, pageCount: 0, summaryStatus: "", favorite: true,
            archived: false, tags: [], createdAt: nil
        )
        let plain = LibraryListItem(
            id: "plain", itemType: "audio", title: "Plain", subtitle: "", status: "completed",
            wordCount: 0, duration: 0, pageCount: 0, summaryStatus: "", favorite: false,
            archived: false, tags: [], createdAt: nil
        )
        let model = LibraryViewModel(previewItems: [favorite, plain])
        model.selectedChip = .starred
        await model.loadIfNeeded(for: model.query)
        XCTAssertEqual(model.items.map(\.id), ["star"])
    }
}

@MainActor
final class AppNavigatorTests: XCTestCase {
    private let reference = LibraryReference(itemType: "audio", itemId: "a")

    func testEachTabKeepsItsOwnStack() {
        let navigator = AppNavigator()
        navigator.select(.library)
        navigator.push(.item(reference))
        navigator.select(.collections)
        navigator.push(.collection("c"))
        navigator.select(.library)
        XCTAssertEqual(navigator.libraryPath, [.item(reference)], "Coming back keeps the place")
        XCTAssertEqual(navigator.collectionsPath, [.collection("c")])
        XCTAssertTrue(navigator.homePath.isEmpty)
    }

    func testTappingTheCurrentTabGoesBackToItsTop() {
        let navigator = AppNavigator(initialTab: .library)
        navigator.push(.item(reference))
        navigator.select(.library)
        XCTAssertTrue(navigator.libraryPath.isEmpty)
    }

    func testTabsAreCreatedOnlyOnceVisited() {
        let navigator = AppNavigator()
        XCTAssertEqual(navigator.visitedTabs, [.home])
        navigator.select(.settings)
        XCTAssertEqual(navigator.visitedTabs, [.home, .settings])
    }

    func testANotificationOpensInTheLibraryFromAnywhere() {
        let navigator = AppNavigator()
        navigator.homePath = [.addLink]
        navigator.libraryPath = [.collection("c")]
        navigator.showRecorder()
        navigator.openFromOutside(reference)
        XCTAssertEqual(navigator.selectedTab, .library)
        XCTAssertEqual(navigator.libraryPath, [.item(reference)])
        XCTAssertFalse(navigator.isRecorderPresented)
        XCTAssertEqual(navigator.homePath, [.addLink], "Home keeps its own place")
    }

    func testTheBarHidesOverFullScreenWorkAndTheRecorder() {
        let navigator = AppNavigator()
        XCTAssertTrue(navigator.showsTabBar)

        navigator.push(.item(reference))
        XCTAssertFalse(navigator.showsTabBar, "A recording's detail takes the whole screen")
        navigator.homePath = [.collection("c")]
        XCTAssertTrue(navigator.showsTabBar)
        navigator.homePath = []

        navigator.showRecorder()
        XCTAssertFalse(navigator.showsTabBar)
        navigator.closeRecorder()
        XCTAssertTrue(navigator.showsTabBar)

        navigator.isTabBarSuppressed = true
        XCTAssertFalse(navigator.showsTabBar)
    }

    func testAHiddenTabsStackDoesNotAffectTheBar() {
        let navigator = AppNavigator()
        navigator.select(.library)
        navigator.push(.item(reference))
        navigator.select(.home)
        XCTAssertTrue(navigator.showsTabBar)
    }
}
