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

    func testClaimSurvivesRelaunchAndOlderManifestsStartUnowned() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let inbox = try ShareInboxStore(rootURL: temp)
        var item = try inbox.stageLink(try XCTUnwrap(URL(string: "https://youtu.be/abc")))
        XCTAssertNil(try inbox.pendingItems().first?.ownerID)

        item.ownerID = "owner-a"
        item.autoTranscribeRequested = true
        try inbox.update(item)

        let afterRelaunch = try XCTUnwrap(ShareInboxStore(rootURL: temp).pendingItems().first)
        XCTAssertEqual(afterRelaunch.ownerID, "owner-a")
        XCTAssertEqual(afterRelaunch.autoTranscribeRequested, true)

        let older = Data(#"{"id":"\#(item.id.uuidString)","originalName":"a","storedName":"link","createdAt":0}"#.utf8)
        let decoded = try JSONDecoder().decode(ShareInboxStore.Item.self, from: older)
        XCTAssertNil(decoded.ownerID)
        XCTAssertNil(decoded.autoTranscribeRequested)
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
        let source = temp.appendingPathComponent("video.avi")
        try Data(repeating: 0x42, count: 16).write(to: source)
        let inbox = try ShareInboxStore(rootURL: temp.appendingPathComponent("inbox"))

        XCTAssertThrowsError(try inbox.stageFile(from: source, originalName: "video.avi"))
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

    private func makeTemporaryInbox() throws -> (temp: URL, inbox: ShareInboxStore) {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temp) }
        return (temp, try ShareInboxStore(rootURL: temp.appendingPathComponent("inbox")))
    }

    private func writeSource(_ name: String, in directory: URL) throws -> URL {
        let source = directory.appendingPathComponent(name)
        try Data(repeating: 0x42, count: 16).write(to: source)
        return source
    }

    func testDottedDisplayNameDoesNotOverrideTheSourceExtension() throws {
        let (temp, inbox) = try makeTemporaryInbox()
        let source = try writeSource("provider.m4a", in: temp)

        let item = try inbox.stageFile(from: source, originalName: "Call v2.1")

        XCTAssertEqual(item.storedName, "source.m4a")
        XCTAssertEqual(item.originalName, "Call v2.1.m4a")
        XCTAssertEqual(item.resolvedKind, .audio)
    }

    func testSourceExtensionWinsOverAConflictingDisplayExtension() throws {
        let (temp, inbox) = try makeTemporaryInbox()
        let source = try writeSource("provider.m4a", in: temp)

        let item = try inbox.stageFile(from: source, originalName: "Meeting.mp3")

        XCTAssertEqual(item.storedName, "source.m4a")
        XCTAssertEqual(item.originalName, "Meeting.m4a")
    }

    func testSharedTypeResolvesANameAndTemporaryFileWithNoUsefulExtension() throws {
        let (temp, inbox) = try makeTemporaryInbox()
        let source = try writeSource("provider.tmp", in: temp)

        let item = try inbox.stageFile(
            from: source,
            originalName: "Call v2.1",
            contentTypeExtension: "m4a"
        )

        XCTAssertEqual(item.storedName, "source.m4a")
        XCTAssertEqual(item.originalName, "Call v2.1.m4a")
    }

    func testNoSupportedExtensionAnywhereIsRejected() throws {
        let (temp, inbox) = try makeTemporaryInbox()
        let source = try writeSource("provider.tmp", in: temp)

        XCTAssertThrowsError(try inbox.stageFile(from: source, originalName: "Call v2.1"))
        XCTAssertTrue(try inbox.pendingItems().isEmpty)
    }

    func testVoiceMemosAndQuickTimeFormatsAreAccepted() throws {
        let (temp, inbox) = try makeTemporaryInbox()

        for fileExtension in ["qta", "mov", "aac"] {
            let source = try writeSource("memo.\(fileExtension)", in: temp)
            let item = try inbox.stageFile(from: source, originalName: "New Recording 3")
            XCTAssertEqual(item.storedName, "source.\(fileExtension)")
            XCTAssertEqual(item.originalName, "New Recording 3.\(fileExtension)")
            XCTAssertEqual(item.resolvedKind, .audio)
        }
    }

    func testPDFIsStagedForTheAppToProcess() throws {
        let (temp, inbox) = try makeTemporaryInbox()
        let source = try writeSource("notes.pdf", in: temp)

        let item = try inbox.stageFile(from: source, originalName: "Notes.pdf")

        XCTAssertEqual(item.resolvedKind, .pdf)
        XCTAssertEqual(try inbox.pendingItems().map(\.id), [item.id])
    }

    func testOversizedPDFIsRejected() throws {
        let (temp, inbox) = try makeTemporaryInbox()
        let source = temp.appendingPathComponent("large.pdf")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 50 * 1_024 * 1_024 + 1)
        try handle.close()

        XCTAssertThrowsError(try inbox.stageFile(from: source, originalName: "large.pdf"))
    }

    func testWebLinkIsStagedAndSurvivesRelaunch() throws {
        let (temp, inbox) = try makeTemporaryInbox()
        let url = try XCTUnwrap(URL(string: "https://youtu.be/abc123"))

        let item = try inbox.stageLink(url, title: "  A talk  ")

        XCTAssertEqual(item.originalName, "A talk")
        let relaunched = try ShareInboxStore(rootURL: temp.appendingPathComponent("inbox"))
        let pending = try XCTUnwrap(relaunched.pendingItems().first)
        XCTAssertEqual(pending.resolvedKind, .link)
        XCTAssertEqual(pending.link, url.absoluteString)
    }

    func testNonWebLinkIsRejected() throws {
        let (_, inbox) = try makeTemporaryInbox()

        for link in ["file:///tmp/a.m4a", "mailto:a@example.com", "https://"] {
            let url = try XCTUnwrap(URL(string: link))
            XCTAssertThrowsError(try inbox.stageLink(url), link)
        }
        XCTAssertTrue(try inbox.pendingItems().isEmpty)
    }

    func testShareStagedByAnOlderBuildIsStillReadAsAudio() throws {
        let (temp, inbox) = try makeTemporaryInbox()
        let id = UUID()
        let directory = inbox.rootURL.appendingPathComponent(id.uuidString.lowercased())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: try writeSource("legacy.m4a", in: temp),
            to: directory.appendingPathComponent("source.m4a")
        )
        let legacy = """
        {"id":"\(id.uuidString)","originalName":"Old.m4a","storedName":"source.m4a","createdAt":0}
        """
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("item.json"))

        let pending = try XCTUnwrap(inbox.pendingItems().first)
        XCTAssertEqual(pending.id, id)
        XCTAssertEqual(pending.resolvedKind, .audio)
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

    /// Voice Memos can leave stale bytes after the last box of a memo it re-saved.
    /// Such a share used to fail every Retry with "invalid audio container".
    @MainActor
    func testSharedVoiceMemoWithStaleTrailingBytesImports() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        func box(_ type: String, _ payload: Data) -> Data {
            let size = UInt32(payload.count + 8)
            return Data([
                UInt8((size >> 24) & 0xff), UInt8((size >> 16) & 0xff),
                UInt8((size >> 8) & 0xff), UInt8(size & 0xff),
            ]) + Data(type.utf8) + payload
        }
        let source = temp.appendingPathComponent("Lance pt. 1.m4a")
        try (box("ftyp", Data("M4A ".utf8)) + box("mdat", Data([1, 2])) + box("moov", Data([3]))
            + box("free", Data("(Build 22H352))".utf8)) + Data("352))".utf8)).write(to: source)
        let inbox = try ShareInboxStore(rootURL: temp.appendingPathComponent("inbox"))
        let item = try inbox.stageFile(from: source, originalName: "Lance pt. 1.m4a")
        let store = try RecordingStore(rootDirectory: temp.appendingPathComponent("recordings"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ShareInboxStoreTests.\(UUID().uuidString)"))
        let coordinator = RecordingCoordinator(store: store, localAccountDefaults: defaults)

        let recording = try coordinator.importRecording(
            from: inbox.fileURL(for: item),
            contentType: "general",
            shareID: item.id,
            originalName: item.originalName
        )

        XCTAssertEqual(recording.state, .ready)
        XCTAssertEqual(recording.displayTitle, "Lance pt. 1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: recording).path))
    }
}
