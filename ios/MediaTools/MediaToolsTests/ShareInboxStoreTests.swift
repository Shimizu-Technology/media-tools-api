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

    func testOriginalExtensionWinsOverTemporaryProviderExtension() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let source = temp.appendingPathComponent("provider.tmp")
        try Data(repeating: 0x42, count: 16).write(to: source)
        let inbox = try ShareInboxStore(rootURL: temp.appendingPathComponent("inbox"))

        let item = try inbox.stageFile(from: source, originalName: "Voice Memo.m4a")
        XCTAssertEqual(item.originalName, "Voice Memo.m4a")
        XCTAssertEqual(item.storedName, "source.m4a")
        XCTAssertEqual(inbox.fileURL(for: item).pathExtension, "m4a")
    }

    func testOversizedFileIsRejectedBeforeCopy() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let source = temp.appendingPathComponent("large.mp4")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 2 * 1_024 * 1_024 * 1_024 + 1)
        try handle.close()
        let inbox = try ShareInboxStore(rootURL: temp.appendingPathComponent("inbox"))

        XCTAssertThrowsError(try inbox.stageFile(from: source, originalName: "large.mp4"))
        XCTAssertTrue(try inbox.pendingItems().isEmpty)
    }

    @MainActor
    func testRepeatedImportOfOneShareDoesNotDuplicateRecording() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let source = temp.appendingPathComponent("memo.mp3")
        try Data(repeating: 0x42, count: 16).write(to: source)
        let inbox = try ShareInboxStore(rootURL: temp.appendingPathComponent("inbox"))
        let item = try inbox.stageFile(from: source, originalName: "memo.mp3")
        let store = try RecordingStore(rootDirectory: temp.appendingPathComponent("recordings"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ShareInboxStoreTests.\(UUID().uuidString)"))
        let coordinator = RecordingCoordinator(store: store, localAccountDefaults: defaults)

        _ = try coordinator.importRecording(from: inbox.fileURL(for: item), contentType: "general", shareID: item.id)
        _ = try coordinator.importRecording(from: inbox.fileURL(for: item), contentType: "general", shareID: item.id)

        XCTAssertEqual(coordinator.pendingRecordings.count, 1)
        XCTAssertEqual(try store.loadRecordings().map(\.id), [item.id])
    }
}
