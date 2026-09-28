import Foundation
import XCTest
@testable import MediaTools

final class ShareInboxStoreTests: XCTestCase {
    func testShareIsPublishedOnlyAfterCopyAndCanBeRecoveredAfterRelaunch() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let source = temp.appendingPathComponent("voice-memo.m4a")
        let bytes = Data(repeating: 0x42, count: 1024)
        try bytes.write(to: source)
        let inboxURL = temp.appendingPathComponent("inbox")

        let first = try ShareInboxStore(rootURL: inboxURL)
        let item = try first.stageFile(from: source, originalName: "Meeting.m4a")
        XCTAssertEqual(try Data(contentsOf: first.fileURL(for: item)), bytes)

        let afterRelaunch = try ShareInboxStore(rootURL: inboxURL)
        XCTAssertEqual(try afterRelaunch.pendingItems().map(\.id), [item.id])
        try afterRelaunch.remove(item)
        XCTAssertTrue(try afterRelaunch.pendingItems().isEmpty)
    }

    func testIncompleteShareIsNeverPublished() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let inbox = try ShareInboxStore(rootURL: temp)
        let incomplete = temp.appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 16).write(to: incomplete.appendingPathComponent("source.m4a"))

        XCTAssertTrue(try inbox.pendingItems().isEmpty)
    }

    func testUnsupportedMovieIsRejectedBeforePublishing() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let source = temp.appendingPathComponent("video.mov")
        try Data(repeating: 0x42, count: 16).write(to: source)
        let inbox = try ShareInboxStore(rootURL: temp.appendingPathComponent("inbox"))

        XCTAssertThrowsError(try inbox.stageFile(from: source, originalName: "video.mov"))
        XCTAssertTrue(try inbox.pendingItems().isEmpty)
    }
}
