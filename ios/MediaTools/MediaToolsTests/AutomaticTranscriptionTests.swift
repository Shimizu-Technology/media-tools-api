import XCTest
import UIKit
@testable import MediaTools

/// Stops every upload at the first network request, which is enough to prove a
/// recording was sent with no taps while its audio stays on the device.
@MainActor
private final class RecordingServiceSpy: RecordingUploadServicing {
    private(set) var presignedFilenames: [String] = []
    private(set) var importedLinks: [String] = []
    private(set) var importedPDFs: [String] = []
    private(set) var documentOwnerIDs: [String?] = []
    private(set) var cancelledDocumentImports = 0
    var documentImportError: Error?
    /// Keeps a document send open until the coordinator cancels it.
    var holdsDocumentImports = false

    private func hold() async throws {
        guard holdsDocumentImports else { return }
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            cancelledDocumentImports += 1
            throw error
        }
    }

    func getAudioItem(_ id: String, expectedOwnerID: String?) async throws -> AudioTranscription {
        throw URLError(.notConnectedToInternet)
    }

    func uploadAudio(
        fileURL: URL,
        filename: String,
        mimeType: String,
        contentType: String,
        expectedOwnerID: String?
    ) async throws -> AudioTranscription {
        throw URLError(.notConnectedToInternet)
    }

    func presignAudioUpload(
        filename: String,
        mimeType: String,
        sizeBytes: Int64,
        expectedOwnerID: String?
    ) async throws -> AudioUploadPresignResponse {
        presignedFilenames.append(filename)
        throw URLError(.notConnectedToInternet)
    }

    func completeAudioUpload(
        _ completion: AudioUploadCompleteRequest,
        expectedOwnerID: String?
    ) async throws -> AudioTranscription {
        throw URLError(.notConnectedToInternet)
    }

    func importSharedLink(_ link: String, expectedOwnerID: String?) async throws {
        documentOwnerIDs.append(expectedOwnerID)
        try await hold()
        if let documentImportError { throw documentImportError }
        importedLinks.append(link)
    }

    func importSharedPDF(fileURL: URL, filename: String, expectedOwnerID: String?) async throws {
        documentOwnerIDs.append(expectedOwnerID)
        try await hold()
        if let documentImportError { throw documentImportError }
        importedPDFs.append(filename)
    }
}

@MainActor
private final class SilentLiveActivities: RecordingActivityManaging {
    let areActivitiesEnabled = true
    func start(for recording: LocalRecording) async throws {}
    func update(recordingID: UUID, isPaused: Bool, isInterrupted: Bool, duration: TimeInterval) async {}
    func end(recordingID: UUID?, finalDuration: TimeInterval) async {}
}

@MainActor
final class AutomaticTranscriptionTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: RecordingStore!
    private var inbox: ShareInboxStore!
    private var consent: AIProcessingConsentManager!
    private var recorder: RecordingCoordinator!
    private var uploader: RecordingUploadCoordinator!
    private var service: RecordingServiceSpy!
    private var appIsForeground = true

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        suiteName = "AutomaticTranscriptionTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        store = try RecordingStore(rootDirectory: directory.appendingPathComponent("recordings"))
        inbox = try ShareInboxStore(rootURL: directory.appendingPathComponent("inbox"))
        service = RecordingServiceSpy()
        appIsForeground = true
        makeCoordinators()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeCoordinators() {
        consent = AIProcessingConsentManager(defaults: defaults)
        recorder = RecordingCoordinator(
            store: store,
            simulatesCapture: true,
            activityManager: SilentLiveActivities(),
            localAccountDefaults: defaults,
            availableCapacity: { _ in 10 * 1_024 * 1_024 * 1_024 },
            shareInbox: inbox
        )
        uploader = RecordingUploadCoordinator(
            recorder: recorder,
            service: service,
            watchStore: try? TranscriptionWatchStore(
                rootDirectory: directory.appendingPathComponent("watches")
            ),
            localAccountDefaults: defaults,
            aiProcessingConsent: consent,
            isForeground: { [unowned self] in self.appIsForeground }
        )
    }

    private func signIn(_ ownerID: String = "owner-a") async {
        consent.setActiveOwnerID(ownerID)
        await uploader.setActiveOwnerID(ownerID)
    }

    private func grantConsent() {
        consent.allow()
    }

    private func recordAndStop() throws -> UUID {
        recorder.start(contentType: "voice_memo")
        recorder.stop()
        return try XCTUnwrap(recorder.pendingRecordings.first?.id)
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            await Task.yield()
        }
    }

    private func assertAudioIsSafe(
        _ recordingID: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let recording = try XCTUnwrap(recorder.recording(withID: recordingID), file: file, line: line)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: store.fileURL(for: recording).path),
            file: file,
            line: line
        )
    }

    // MARK: - Stop

    func testStoppingQueuesWithoutATapWhenConsentAndSettingAreOn() async throws {
        await signIn()
        grantConsent()

        let id = try recordAndStop()

        XCTAssertTrue(recorder.recording(withID: id)?.isUploadInProgress == true)
        await settle { !service.presignedFilenames.isEmpty }
        XCTAssertEqual(service.presignedFilenames.count, 1)
        try assertAudioIsSafe(id)
    }

    func testStoppingFromTheSystemQueuesTheSameWay() async throws {
        await signIn()
        grantConsent()
        _ = await recorder.toggleFromSystem()
        let id = try XCTUnwrap(recorder.pendingRecordings.first?.id)
        XCTAssertEqual(recorder.recording(withID: id)?.state, .recording)

        _ = await recorder.toggleFromSystem()

        XCTAssertTrue(recorder.recording(withID: id)?.isUploadInProgress == true)
    }

    func testSettingOffLeavesTheRecordingForAManualTap() async throws {
        await signIn()
        grantConsent()
        consent.setAutoTranscribeEnabled(false)

        let id = try recordAndStop()

        await settle { !service.presignedFilenames.isEmpty }
        XCTAssertEqual(recorder.recording(withID: id)?.state, .ready)
        XCTAssertTrue(service.presignedFilenames.isEmpty)
        try assertAudioIsSafe(id)
    }

    func testTurningTheSettingOnDoesNotSendRecordingsSavedWhileItWasOff() async throws {
        await signIn()
        grantConsent()
        consent.setAutoTranscribeEnabled(false)
        let saved = try recordAndStop()

        consent.setAutoTranscribeEnabled(true)

        XCTAssertEqual(recorder.recording(withID: saved)?.state, .ready)
        XCTAssertTrue(service.presignedFilenames.isEmpty)
    }

    func testRecordingSavedWhileTheSettingWasOnWaitsIfTurnedOffThenSendsWhenBackOn() async throws {
        await signIn()
        let id = try recordAndStop()
        // Dismiss the first prompt, then decide later.
        consent.decline()
        consent.setAutoTranscribeEnabled(false)
        grantConsent()
        XCTAssertEqual(recorder.recording(withID: id)?.state, .ready)

        consent.setAutoTranscribeEnabled(true)

        XCTAssertTrue(recorder.recording(withID: id)?.isUploadInProgress == true)
    }

    func testAFailedUploadIsNotRetriedOnEveryForeground() async throws {
        await signIn()
        grantConsent()
        consent.setAutoTranscribeEnabled(false)
        let id = try recordAndStop()
        recorder.markUploadFailed(id, message: "Rejected")
        consent.setAutoTranscribeEnabled(true)

        uploader.resumePendingWork()

        XCTAssertEqual(recorder.recording(withID: id)?.state, .uploadFailed)
    }

    // MARK: - Consent

    func testWithoutConsentAsksOnceAndKeepsTheRecording() async throws {
        await signIn()

        let first = try recordAndStop()

        XCTAssertTrue(consent.isPresentingDisclosure)
        XCTAssertEqual(recorder.recording(withID: first)?.state, .ready)
        consent.decline()

        let second = try recordAndStop()
        uploader.resumePendingWork()

        XCTAssertFalse(consent.isPresentingDisclosure)
        XCTAssertEqual(recorder.recording(withID: first)?.state, .ready)
        XCTAssertEqual(recorder.recording(withID: second)?.state, .ready)
        XCTAssertTrue(service.presignedFilenames.isEmpty)
        try assertAudioIsSafe(first)
        try assertAudioIsSafe(second)
    }

    func testDecliningIsRememberedAcrossRelaunch() async throws {
        await signIn()
        _ = try recordAndStop()
        consent.decline()

        makeCoordinators()
        await signIn()

        XCTAssertFalse(consent.isPresentingDisclosure)
    }

    func testAllowingLaterInSettingsSendsEverythingWaiting() async throws {
        await signIn()
        let first = try recordAndStop()
        consent.decline()
        let second = try recordAndStop()

        let request = Task { await self.consent.requestAutomaticPermission() }
        await settle { consent.isPresentingDisclosure }
        consent.allow()
        let granted = await request.value

        XCTAssertTrue(granted)
        XCTAssertTrue(recorder.recording(withID: first)?.isUploadInProgress == true)
        XCTAssertTrue(recorder.recording(withID: second)?.isUploadInProgress == true)
    }

    func testPromptWaitsForTheForeground() async throws {
        await signIn()
        appIsForeground = false

        let id = try recordAndStop()

        XCTAssertFalse(consent.isPresentingDisclosure)
        appIsForeground = true
        uploader.resumePendingWork()
        XCTAssertTrue(consent.isPresentingDisclosure)
        consent.allow()
        XCTAssertTrue(recorder.recording(withID: id)?.isUploadInProgress == true)
    }

    func testPromptDoesNotInterruptAnActiveRecording() async throws {
        await signIn()
        consent.setAutoTranscribeEnabled(false)
        _ = try recordAndStop()
        consent.setAutoTranscribeEnabled(true)
        recorder.start(contentType: "voice_memo")

        uploader.resumePendingWork()

        XCTAssertFalse(consent.isPresentingDisclosure)
        recorder.stop()
        XCTAssertTrue(consent.isPresentingDisclosure)
    }

    func testAGrantUnderTheOldCopyDoesNotCoverAutomaticUploads() async throws {
        defaults.set(["owner-a"], forKey: "aiProcessingConsentedOwnerIDs.v1")
        await signIn()
        XCTAssertTrue(consent.hasConsent)
        XCTAssertFalse(consent.hasAutomaticConsent)

        let id = try recordAndStop()

        XCTAssertEqual(recorder.recording(withID: id)?.state, .ready)
        XCTAssertTrue(consent.isPresentingDisclosure)
        consent.allow()
        XCTAssertTrue(recorder.recording(withID: id)?.isUploadInProgress == true)
    }

    func testRevokingReturnsQueuedRecordingsSoTheyCanStillBeDiscarded() async throws {
        await signIn()
        grantConsent()
        let id = try recordAndStop()
        XCTAssertEqual(recorder.recording(withID: id)?.state, .waitingForUpload)

        consent.revoke()

        let recording = try XCTUnwrap(recorder.recording(withID: id))
        XCTAssertEqual(recording.state, .ready)
        XCTAssertFalse(recording.isUploadInProgress)
        try assertAudioIsSafe(id)
        XCTAssertFalse(consent.isPresentingDisclosure)

        grantConsent()
        XCTAssertEqual(recorder.recording(withID: id)?.state, .ready)
    }

    func testAQueuedRecordingWaitingForAConnectionCanStillBeDiscarded() async throws {
        await signIn()
        grantConsent()
        let id = try recordAndStop()
        XCTAssertEqual(recorder.recording(withID: id)?.state, .waitingForUpload)
        let fileURL = try XCTUnwrap(recorder.recording(withID: id).map(store.fileURL(for:)))

        uploader.discard(try XCTUnwrap(recorder.recording(withID: id)))

        XCTAssertNil(recorder.recording(withID: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(try store.loadRecordings().contains { $0.id == id })
    }

    func testARecordingAlreadyUploadingCannotBeDiscarded() async throws {
        await signIn()
        grantConsent()
        let id = try recordAndStop()
        recorder.markUploadStarted(
            id,
            objectKey: "audio/key",
            sizeBytes: 1,
            mimeType: "audio/x-caf",
            taskIdentifier: 1
        )

        uploader.discard(try XCTUnwrap(recorder.recording(withID: id)))

        XCTAssertEqual(recorder.recording(withID: id)?.state, .uploading)
        try assertAudioIsSafe(id)
    }

    func testPreferenceFollowsAVerifiedAccountMigration() async throws {
        consent.setActiveOwnerID("clerk-a")
        consent.setAutoTranscribeEnabled(false)
        consent.allow()

        consent.migrateConsent(from: "clerk-a", to: "user-a")

        XCTAssertFalse(consent.isAutoTranscribeEnabled(ownerID: "user-a"))
        XCTAssertTrue(consent.hasAutomaticConsent(ownerID: "user-a"))
        XCTAssertTrue(consent.isAutoTranscribeEnabled(ownerID: "clerk-a"))
    }

    // MARK: - Signed-out capture

    func testSignedOutRecordingIsClaimedAndSentAfterSignInAndConsent() async throws {
        let id = try recordAndStop()
        XCTAssertNil(recorder.recording(withID: id)?.ownerID)
        XCTAssertEqual(recorder.recording(withID: id)?.state, .ready)
        XCTAssertFalse(consent.isPresentingDisclosure)

        await signIn()

        XCTAssertEqual(recorder.recording(withID: id)?.ownerID, "owner-a")
        XCTAssertTrue(consent.isPresentingDisclosure)
        consent.allow()
        XCTAssertTrue(recorder.recording(withID: id)?.isUploadInProgress == true)
        try assertAudioIsSafe(id)
    }

    func testSignedOutRecordingRespectsTheClaimingAccountsSetting() async throws {
        let id = try recordAndStop()
        consent.setActiveOwnerID("owner-a")
        consent.setAutoTranscribeEnabled(false)
        consent.allow()

        await uploader.setActiveOwnerID("owner-a")

        XCTAssertEqual(recorder.recording(withID: id)?.state, .ready)
    }

    // MARK: - Recovery and older builds

    func testRecordingFromAnOlderBuildIsNotSentAutomatically() async throws {
        var legacy = store.makeRecording(contentType: "general", ownerID: "owner-a")
        legacy.state = .ready
        legacy.autoTranscribeRequested = nil
        try simulatedCAF(at: store.fileURL(for: legacy))
        try store.saveRecordings([legacy])
        makeCoordinators()
        await signIn()
        grantConsent()

        uploader.resumePendingWork()

        XCTAssertEqual(recorder.recording(withID: legacy.id)?.state, .ready)
        XCTAssertNil(recorder.recording(withID: legacy.id)?.autoTranscribeRequested)
    }

    func testManifestWithoutTheFlagStillDecodes() throws {
        let manifest = """
        {"id":"\(UUID().uuidString)","filename":"a.m4a","createdAt":0,"duration":1,\
        "contentType":"general","state":"ready"}
        """
        let decoded = try JSONDecoder().decode(LocalRecording.self, from: Data(manifest.utf8))
        XCTAssertNil(decoded.autoTranscribeRequested)
        XCTAssertFalse(decoded.isWaitingForAutomaticTranscription)
    }

    func testRecordingRecoveredAfterACrashIsSentOnRelaunch() async throws {
        await signIn()
        grantConsent()
        recorder.start(contentType: "voice_memo")
        let id = try XCTUnwrap(recorder.pendingRecordings.first?.id)
        XCTAssertEqual(recorder.recording(withID: id)?.state, .recording)

        // A new coordinator over the same manifest is what a relaunch looks like.
        makeCoordinators()
        XCTAssertEqual(recorder.recording(withID: id)?.state, .interrupted)
        await signIn()

        XCTAssertTrue(recorder.recording(withID: id)?.isUploadInProgress == true)
        try assertAudioIsSafe(id)
    }

    // MARK: - Shares

    func testSharedAudioIsImportedAndQueuedWithoutATap() async throws {
        await signIn()
        grantConsent()
        let source = directory.appendingPathComponent("memo.caf")
        try simulatedCAF(at: source)
        let item = try inbox.stageFile(from: source, originalName: "Call v2.1")

        uploader.processSharedItems()

        XCTAssertTrue(try inbox.pendingItems().isEmpty)
        XCTAssertTrue(recorder.recording(withID: item.id)?.isUploadInProgress == true)
        await settle { !service.presignedFilenames.isEmpty }
        XCTAssertEqual(service.presignedFilenames, ["Call v2.1.caf"])
    }

    func testSharedAudioWaitsForSignInAndKeepsTheInboxCopySafe() async throws {
        let source = directory.appendingPathComponent("memo.caf")
        try simulatedCAF(at: source)
        let item = try inbox.stageFile(from: source, originalName: "memo.caf")

        uploader.processSharedItems()

        XCTAssertEqual(recorder.recording(withID: item.id)?.state, .ready)
        XCTAssertTrue(service.presignedFilenames.isEmpty)

        await signIn()
        grantConsent()
        XCTAssertTrue(recorder.recording(withID: item.id)?.isUploadInProgress == true)
    }

    func testSharedLinkAndPDFReachTheServerAndLeaveTheInbox() async throws {
        await signIn()
        grantConsent()
        let pdf = directory.appendingPathComponent("notes.pdf")
        try Data("%PDF-1.4".utf8).write(to: pdf)
        _ = try inbox.stageFile(from: pdf, originalName: "Notes.pdf")
        _ = try inbox.stageLink(try XCTUnwrap(URL(string: "https://youtu.be/abc")))

        uploader.processSharedItems()

        await settle { (try? inbox.pendingItems().isEmpty) == true }
        XCTAssertEqual(service.importedLinks, ["https://youtu.be/abc"])
        XCTAssertEqual(service.importedPDFs, ["Notes.pdf"])
        XCTAssertTrue(recorder.pendingSharedItems.isEmpty)
        XCTAssertEqual(uploader.sharedDocumentImports, 2)
    }

    func testFailedSharedLinkStaysStagedWithAMessageAndRetries() async throws {
        await signIn()
        grantConsent()
        service.documentImportError = URLError(.notConnectedToInternet)
        let item = try inbox.stageLink(try XCTUnwrap(URL(string: "https://youtu.be/abc")))

        uploader.processSharedItems()

        await settle { recorder.pendingSharedErrors[item.id] != nil }
        XCTAssertNotNil(recorder.pendingSharedErrors[item.id])
        XCTAssertEqual(try inbox.pendingItems().map(\.id), [item.id])

        service.documentImportError = nil
        await settle { true }
        uploader.processSharedItems()
        await settle { (try? inbox.pendingItems().isEmpty) == true }
        XCTAssertTrue(try inbox.pendingItems().isEmpty)
        XCTAssertNil(recorder.pendingSharedErrors[item.id])
    }

    func testRejectedLinkWaitsForAManualRetryInsteadOfRepeatingOnForeground() async throws {
        await signIn()
        grantConsent()
        service.documentImportError = APIError.httpError(
            statusCode: 400,
            message: "This page has no video."
        )
        let item = try inbox.stageLink(try XCTUnwrap(URL(string: "https://example.com/article")))
        uploader.processSharedItems()
        await settle { recorder.pendingSharedErrors[item.id] != nil }
        XCTAssertEqual(recorder.sharesNeedingAttention.map(\.id), [item.id])

        service.documentImportError = nil
        uploader.processSharedItems()
        await settle { !service.importedLinks.isEmpty }
        XCTAssertTrue(service.importedLinks.isEmpty, "A foreground must not resend a rejected share")
        XCTAssertEqual(try inbox.pendingItems().map(\.id), [item.id])

        await uploader.retrySharedItem(item)
        await settle { !service.importedLinks.isEmpty }
        XCTAssertEqual(service.importedLinks, ["https://example.com/article"])
    }

    func testRemovingAShareIsTheOnlyWayItLeavesTheInboxUnprocessed() async throws {
        await signIn()
        grantConsent()
        service.documentImportError = APIError.httpError(statusCode: 400, message: "No video")
        let item = try inbox.stageLink(try XCTUnwrap(URL(string: "https://example.com/article")))
        uploader.processSharedItems()
        await settle { recorder.pendingSharedErrors[item.id] != nil }

        recorder.discardSharedItem(item)

        XCTAssertTrue(try inbox.pendingItems().isEmpty)
        XCTAssertTrue(recorder.sharesNeedingAttention.isEmpty)
        XCTAssertNil(recorder.pendingSharedErrors[item.id])
    }

    func testDocumentOnItsWayDoesNotReadAsNeedingAttention() async throws {
        let item = try inbox.stageLink(try XCTUnwrap(URL(string: "https://youtu.be/abc")))
        uploader.processSharedItems()

        XCTAssertEqual(recorder.pendingSharedItems.map(\.id), [item.id])
        XCTAssertTrue(recorder.sharesNeedingAttention.isEmpty)
    }

    func testRecordingStoppedDuringAccountDeletionIsNotSent() async throws {
        await signIn()
        grantConsent()
        defaults.set(["owner-a"], forKey: RecordingUploadCoordinator.pendingLocalAccountDeletionOwnerIDsKey)

        let id = try recordAndStop()

        XCTAssertEqual(recorder.recording(withID: id)?.state, .ready)
        XCTAssertTrue(service.presignedFilenames.isEmpty)
    }

    func testSignedOutDocumentStaysInTheInbox() throws {
        let item = try inbox.stageLink(try XCTUnwrap(URL(string: "https://youtu.be/abc")))

        uploader.processSharedItems()

        XCTAssertEqual(recorder.pendingSharedItems.map(\.id), [item.id])
        XCTAssertTrue(service.importedLinks.isEmpty)
    }

    // MARK: - Shared link consent

    private func stageLink(_ link: String = "https://youtu.be/abc") throws -> ShareInboxStore.Item {
        try inbox.stageLink(try XCTUnwrap(URL(string: link)))
    }

    private func stagePDF() throws -> ShareInboxStore.Item {
        let pdf = directory.appendingPathComponent("\(UUID().uuidString).pdf")
        try Data("%PDF-1.4".utf8).write(to: pdf)
        return try inbox.stageFile(from: pdf, originalName: "Notes.pdf")
    }

    func testSharedLinkIsNotSentWithoutConsentAndSendsOnceAllowed() async throws {
        await signIn()
        let item = try stageLink()

        uploader.processSharedItems()
        await settle { !service.importedLinks.isEmpty }

        XCTAssertTrue(service.importedLinks.isEmpty, "A link can reach Whisper, so it needs consent")
        XCTAssertEqual(try inbox.pendingItems().map(\.id), [item.id])
        XCTAssertTrue(consent.isPresentingDisclosure)

        consent.allow()
        await settle { !service.importedLinks.isEmpty }
        XCTAssertEqual(service.importedLinks, ["https://youtu.be/abc"])
    }

    func testDeclinedLinkStaysHereWithAManualActionAndDoesNotAskAgain() async throws {
        await signIn()
        let item = try stageLink()
        uploader.processSharedItems()
        consent.decline()

        uploader.processSharedItems()

        XCTAssertFalse(consent.isPresentingDisclosure)
        let waiting = try XCTUnwrap(uploader.sharesNeedingAttention.first)
        XCTAssertEqual(waiting.id, item.id)
        XCTAssertEqual(uploader.shareActionTitle(for: waiting), "Transcribe")
        XCTAssertFalse(uploader.shareStatusMessage(for: waiting).isEmpty)
        XCTAssertEqual(try inbox.pendingItems().map(\.id), [item.id])

        // Tapping asks; declining again still keeps the share.
        let declined = Task { await uploader.retrySharedItem(item) }
        await settle { consent.isPresentingDisclosure }
        consent.decline()
        await declined.value
        XCTAssertTrue(service.importedLinks.isEmpty)
        XCTAssertEqual(try inbox.pendingItems().map(\.id), [item.id])

        let allowed = Task { await uploader.retrySharedItem(item) }
        await settle { consent.isPresentingDisclosure }
        consent.allow()
        await allowed.value
        await settle { (try? inbox.pendingItems().isEmpty) == true }
        XCTAssertEqual(service.importedLinks, ["https://youtu.be/abc"])
        XCTAssertTrue(uploader.sharesNeedingAttention.isEmpty)
    }

    func testAGrantUnderTheOldCopyOnlyCoversATappedLink() async throws {
        defaults.set(["owner-a"], forKey: "aiProcessingConsentedOwnerIDs.v1")
        await signIn()
        let item = try stageLink()

        uploader.processSharedItems()
        await settle { !service.importedLinks.isEmpty }
        XCTAssertTrue(service.importedLinks.isEmpty)
        consent.decline()

        await uploader.retrySharedItem(item)
        await settle { !service.importedLinks.isEmpty }
        XCTAssertEqual(service.importedLinks, ["https://youtu.be/abc"])
    }

    func testLinkClaimedWithTheSettingOffStaysManualAfterItTurnsOn() async throws {
        await signIn()
        grantConsent()
        consent.setAutoTranscribeEnabled(false)
        let item = try stageLink()
        uploader.processSharedItems()
        XCTAssertEqual(uploader.sharesNeedingAttention.map(\.id), [item.id])

        consent.setAutoTranscribeEnabled(true)
        await settle { !service.importedLinks.isEmpty }
        XCTAssertTrue(service.importedLinks.isEmpty)

        await uploader.retrySharedItem(item)
        await settle { !service.importedLinks.isEmpty }
        XCTAssertEqual(service.importedLinks, ["https://youtu.be/abc"])
    }

    func testRevokingStopsALinkBeingSentAndKeepsItHere() async throws {
        await signIn()
        grantConsent()
        service.holdsDocumentImports = true
        let item = try stageLink()
        uploader.processSharedItems()
        await settle { !service.documentOwnerIDs.isEmpty }

        consent.revoke()
        await settle { service.cancelledDocumentImports == 1 }

        XCTAssertEqual(service.cancelledDocumentImports, 1)
        XCTAssertEqual(try inbox.pendingItems().map(\.id), [item.id])
        XCTAssertEqual(uploader.sharesNeedingAttention.map(\.id), [item.id])
    }

    func testPDFIsSentWithoutConsentBecauseExtractionUsesNoAI() async throws {
        await signIn()
        _ = try stagePDF()

        uploader.processSharedItems()
        await settle { !service.importedPDFs.isEmpty }

        XCTAssertEqual(service.importedPDFs, ["Notes.pdf"])
        XCTAssertEqual(service.documentOwnerIDs, ["owner-a"])
        XCTAssertFalse(consent.isPresentingDisclosure)
    }

    // MARK: - Shared document ownership

    func testFailedShareNeverUploadsIntoAnotherAccount() async throws {
        await signIn("owner-a")
        service.documentImportError = URLError(.notConnectedToInternet)
        let item = try stagePDF()
        uploader.processSharedItems()
        await settle { recorder.pendingSharedErrors[item.id] != nil }
        XCTAssertEqual(service.documentOwnerIDs, ["owner-a"])

        service.documentImportError = nil
        consent.setActiveOwnerID("owner-b")
        await uploader.setActiveOwnerID("owner-b")
        uploader.processSharedItems()
        await settle { service.documentOwnerIDs.count > 1 }

        XCTAssertEqual(service.documentOwnerIDs, ["owner-a"])
        XCTAssertTrue(uploader.sharesNeedingAttention.isEmpty)
        XCTAssertTrue(recorder.availableSharedItems.isEmpty)

        await signIn("owner-a")
        await settle { (try? inbox.pendingItems().isEmpty) == true }
        XCTAssertEqual(service.documentOwnerIDs, ["owner-a", "owner-a"])
    }

    func testFirstSignedInAccountClaimsAShareDurablyAcrossRelaunch() async throws {
        service.documentImportError = URLError(.notConnectedToInternet)
        let item = try stagePDF()
        uploader.processSharedItems()
        XCTAssertNil(try inbox.pendingItems().first?.ownerID)

        await signIn("owner-a")
        await settle { recorder.pendingSharedErrors[item.id] != nil }
        XCTAssertEqual(try inbox.pendingItems().first?.ownerID, "owner-a")

        makeCoordinators()
        service.documentImportError = nil
        await signIn("owner-b")
        await settle { service.documentOwnerIDs.count > 1 }
        XCTAssertEqual(service.documentOwnerIDs, ["owner-a"])
        XCTAssertEqual(try inbox.pendingItems().map(\.id), [item.id])
    }

    func testAClaimThatCouldNotBeSavedBlocksSendingAndStaysWithThatAccount() async throws {
        await signIn("owner-a")
        let item = try stagePDF()
        let itemDirectory = inbox.rootURL.appendingPathComponent(item.id.uuidString.lowercased())
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: itemDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: itemDirectory.path) }

        uploader.processSharedItems()
        await settle { !service.documentOwnerIDs.isEmpty }
        XCTAssertTrue(service.documentOwnerIDs.isEmpty, "Nothing is sent before the claim is saved")

        consent.setActiveOwnerID("owner-b")
        await uploader.setActiveOwnerID("owner-b")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: itemDirectory.path)
        uploader.processSharedItems()

        XCTAssertEqual(try inbox.pendingItems().first?.ownerID, "owner-a")
        await settle { !service.documentOwnerIDs.isEmpty }
        XCTAssertTrue(service.documentOwnerIDs.isEmpty)
    }

    func testSigningOutCancelsASendAndTheShareWaitsForItsOwner() async throws {
        await signIn("owner-a")
        service.holdsDocumentImports = true
        let item = try stagePDF()
        uploader.processSharedItems()
        await settle { !service.documentOwnerIDs.isEmpty }

        await uploader.setActiveOwnerID(nil)
        await settle { service.cancelledDocumentImports == 1 }

        XCTAssertEqual(service.cancelledDocumentImports, 1)
        XCTAssertEqual(try inbox.pendingItems().map(\.id), [item.id])
        XCTAssertTrue(recorder.availableSharedItems.isEmpty)
    }

    func testSwitchingAccountsCancelsASendForThePreviousOwner() async throws {
        await signIn("owner-a")
        service.holdsDocumentImports = true
        _ = try stagePDF()
        uploader.processSharedItems()
        await settle { !service.documentOwnerIDs.isEmpty }

        await signIn("owner-b")
        await settle { service.cancelledDocumentImports == 1 }

        XCTAssertEqual(service.cancelledDocumentImports, 1)
        XCTAssertEqual(service.documentOwnerIDs, ["owner-a"])
    }

    func testVerifiedMigrationMovesAShareToTheNewOwnerID() async throws {
        service.documentImportError = URLError(.notConnectedToInternet)
        await signIn("clerk-a")
        let item = try stagePDF()
        uploader.processSharedItems()
        await settle { recorder.pendingSharedErrors[item.id] != nil }

        try await uploader.migrateOwnerID(from: "clerk-a", to: "server-a")

        XCTAssertEqual(try inbox.pendingItems().first?.ownerID, "server-a")
    }

    func testDeletingAnAccountRemovesItsSharesButNotAnotherAccounts() async throws {
        service.documentImportError = URLError(.notConnectedToInternet)
        await signIn("owner-a")
        let owned = try stagePDF()
        uploader.processSharedItems()
        await settle { recorder.pendingSharedErrors[owned.id] != nil }
        await signIn("owner-b")
        let other = try stagePDF()
        uploader.processSharedItems()
        await settle { recorder.pendingSharedErrors[other.id] != nil }

        await uploader.removeLocalAccountData(ownerID: "owner-a")

        XCTAssertEqual(try inbox.pendingItems().map(\.id), [other.id])
    }

    // MARK: - Signed-out shares

    func testSignedOutDocumentsSendThemselvesAfterSignIn() async throws {
        await signIn("owner-a")
        grantConsent()
        await uploader.setActiveOwnerID(nil)
        consent.setActiveOwnerID(nil)
        _ = try stagePDF()
        _ = try stageLink()
        uploader.processSharedItems()
        XCTAssertEqual(recorder.availableSharedItems.count, 2)
        XCTAssertTrue(service.documentOwnerIDs.isEmpty)

        // Nothing but signing in: no foreground and no Retry.
        await signIn("owner-a")

        await settle { (try? inbox.pendingItems().isEmpty) == true }
        XCTAssertTrue(try inbox.pendingItems().isEmpty)
        XCTAssertEqual(service.importedPDFs, ["Notes.pdf"])
        XCTAssertEqual(service.importedLinks, ["https://youtu.be/abc"])
    }

    // MARK: - Revocation

    func testRevocationInterruptedByTerminationLeavesRecordingsActionable() async throws {
        await signIn()
        grantConsent()
        consent.revoke()
        var recordings: [LocalRecording] = []
        for state in [LocalRecordingState.waitingForUpload, .uploading, .finalizingUpload] {
            var recording = store.makeRecording(contentType: "general", ownerID: "owner-a")
            recording.state = state
            recording.autoTranscribeRequested = true
            recording.uploadObjectKey = "audio/key"
            recording.uploadSizeBytes = 42
            try simulatedCAF(at: store.fileURL(for: recording))
            recordings.append(recording)
        }
        try store.saveRecordings(recordings)

        makeCoordinators()
        await signIn()

        for recording in recordings {
            let current = try XCTUnwrap(recorder.recording(withID: recording.id))
            XCTAssertEqual(current.state, .ready)
            XCTAssertTrue(current.canUpload)
            XCTAssertNotEqual(current.autoTranscribeRequested, true)
        }
        XCTAssertEqual(try store.loadRecordings().map(\.state), [.ready, .ready, .ready])

        // Discard works again, and so does a deliberate Transcribe.
        uploader.discard(try XCTUnwrap(recorder.recording(withID: recordings[0].id)))
        XCTAssertNil(recorder.recording(withID: recordings[0].id))

        grantConsent()
        await settle { true }
        XCTAssertEqual(recorder.recording(withID: recordings[1].id)?.state, .ready)
        uploader.queue(try XCTUnwrap(recorder.recording(withID: recordings[1].id)))
        await settle { !service.presignedFilenames.isEmpty }
        XCTAssertEqual(service.presignedFilenames.count, 1)
    }

    func testConsentMigrationGapIsNotTreatedAsARevocation() async throws {
        await signIn("clerk-a")
        grantConsent()
        let id = try recordAndStop()
        XCTAssertTrue(recorder.recording(withID: id)?.isUploadInProgress == true)

        try await uploader.migrateOwnerID(from: "clerk-a", to: "server-a")
        recorder.setActiveOwnerID("server-a")
        uploader.resumePendingWork()

        XCTAssertTrue(recorder.recording(withID: id)?.isUploadInProgress == true)
    }

    func testResumingWithConsentLeavesQueuedWorkAlone() async throws {
        await signIn()
        grantConsent()
        var recording = store.makeRecording(contentType: "general", ownerID: "owner-a")
        recording.state = .waitingForUpload
        try simulatedCAF(at: store.fileURL(for: recording))
        try store.saveRecordings([recording])

        makeCoordinators()
        await signIn()

        XCTAssertTrue(recorder.recording(withID: recording.id)?.isUploadInProgress == true)
    }

    // MARK: - Restoring after unlock

    private var manifestURL: URL {
        store.directoryURL.appendingPathComponent("recordings.json")
    }

    /// A manifest that exists but cannot be read, as before first unlock.
    private func lockManifest() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: manifestURL.path)
    }

    private func unlockManifest() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: manifestURL.path)
    }

    private func savedRecording(
        ownerID: String? = "owner-a",
        state: LocalRecordingState = .ready,
        autoTranscribe: Bool = false
    ) throws -> LocalRecording {
        var recording = store.makeRecording(contentType: "general", ownerID: ownerID)
        recording.state = state
        recording.autoTranscribeRequested = autoTranscribe
        try simulatedCAF(at: store.fileURL(for: recording))
        try store.saveRecordings([recording])
        return recording
    }

    func testLockedManifestIsNeverOverwrittenAndRestoresAtUnlock() async throws {
        let earlier = try savedRecording()
        let original = try Data(contentsOf: manifestURL)
        try lockManifest()
        defer { try? unlockManifest() }

        makeCoordinators()
        await signIn()
        XCTAssertNil(recorder.recording(withID: earlier.id))
        XCTAssertNotNil(recorder.errorMessage)

        // Every write path a person can reach while the manifest is closed.
        let newID = try recordAndStop()
        XCTAssertEqual(recorder.recording(withID: newID)?.state, .ready)

        try unlockManifest()
        XCTAssertEqual(try Data(contentsOf: manifestURL), original, "The manifest must not be replaced")

        NotificationCenter.default.post(
            name: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil
        )
        await settle { recorder.recording(withID: earlier.id) != nil }

        XCTAssertNotNil(recorder.recording(withID: earlier.id))
        XCTAssertNotNil(recorder.recording(withID: newID))
        XCTAssertNil(recorder.errorMessage)
        XCTAssertEqual(
            Set(try store.loadRecordings().map(\.id)),
            [earlier.id, newID]
        )
        XCTAssertTrue(try store.loadUnmergedRecordings().isEmpty)
        try assertAudioIsSafe(earlier.id)
        try assertAudioIsSafe(newID)
    }

    func testCaptureWhileLockedSurvivesTerminationAndStillMerges() async throws {
        let earlier = try savedRecording()
        try lockManifest()
        defer { try? unlockManifest() }

        makeCoordinators()
        await signIn()
        recorder.start(contentType: "voice_memo")
        let capturing = try XCTUnwrap(recorder.pendingRecordings.first?.id)

        // The app ends mid-capture, and relaunches still locked.
        makeCoordinators()
        await signIn()
        XCTAssertEqual(recorder.recording(withID: capturing)?.state, .interrupted)
        XCTAssertNil(recorder.recording(withID: earlier.id))

        try unlockManifest()
        recorder.retryRestorationIfNeeded()

        XCTAssertNotNil(recorder.recording(withID: earlier.id))
        XCTAssertEqual(recorder.recording(withID: capturing)?.state, .interrupted)
        XCTAssertEqual(Set(try store.loadRecordings().map(\.id)), [earlier.id, capturing])
        try assertAudioIsSafe(capturing)
    }

    func testRestoringDuringACaptureLeavesItRecording() async throws {
        let earlier = try savedRecording()
        try lockManifest()
        defer { try? unlockManifest() }

        makeCoordinators()
        await signIn()
        recorder.start(contentType: "voice_memo")
        let capturing = try XCTUnwrap(recorder.pendingRecordings.first?.id)

        try unlockManifest()
        recorder.retryRestorationIfNeeded()

        XCTAssertNotNil(recorder.recording(withID: earlier.id))
        XCTAssertEqual(recorder.recording(withID: capturing)?.state, .recording)
        XCTAssertTrue(recorder.isRecording)

        recorder.stop()
        XCTAssertEqual(recorder.recording(withID: capturing)?.state, .ready)
        XCTAssertEqual(Set(try store.loadRecordings().map(\.id)), [earlier.id, capturing])
    }

    func testDiscardingWhileLockedDoesNotComeBackAfterUnlock() async throws {
        let earlier = try savedRecording()
        try lockManifest()
        defer { try? unlockManifest() }

        makeCoordinators()
        await signIn()
        let newID = try recordAndStop()
        uploader.discard(try XCTUnwrap(recorder.recording(withID: newID)))
        XCTAssertTrue(try store.loadUnmergedRecordings().isEmpty)

        try unlockManifest()
        recorder.retryRestorationIfNeeded()

        XCTAssertEqual(try store.loadRecordings().map(\.id), [earlier.id])
    }

    func testRestoredWorkIsClaimedAndResumesWithoutARelaunch() async throws {
        await signIn()
        grantConsent()
        let unowned = try savedRecording(ownerID: nil, autoTranscribe: true)
        try lockManifest()
        defer { try? unlockManifest() }

        makeCoordinators()
        await signIn()
        XCTAssertTrue(service.presignedFilenames.isEmpty)

        try unlockManifest()
        recorder.retryRestorationIfNeeded()
        await settle { !service.presignedFilenames.isEmpty }

        XCTAssertEqual(recorder.recording(withID: unowned.id)?.ownerID, "owner-a")
        XCTAssertEqual(service.presignedFilenames.count, 1)
        XCTAssertEqual(try store.loadRecordings().first?.ownerID, "owner-a")
    }

    func testMigrationWaitsForTheManifestSoNoRecordingKeepsAnOldOwner() async throws {
        let earlier = try savedRecording(ownerID: "clerk-a")
        try lockManifest()
        defer { try? unlockManifest() }

        makeCoordinators()
        do {
            try await uploader.migrateOwnerID(from: "clerk-a", to: "server-a")
            XCTFail("Migration must wait until the manifest can be read")
        } catch {}

        try unlockManifest()
        try await uploader.migrateOwnerID(from: "clerk-a", to: "server-a")

        XCTAssertEqual(recorder.recording(withID: earlier.id)?.ownerID, "server-a")
        XCTAssertEqual(try store.loadRecordings().first?.ownerID, "server-a")
    }

    func testAccountDeletionWaitsForTheManifestAndThenFinishes() async throws {
        _ = try savedRecording()
        try lockManifest()
        defer { try? unlockManifest() }

        makeCoordinators()
        await signIn()
        await uploader.removeLocalAccountData(ownerID: "owner-a")
        XCTAssertTrue(uploader.hasPendingLocalAccountDeletion(ownerID: "owner-a"))

        try unlockManifest()
        await uploader.setActiveOwnerID("owner-b")

        XCTAssertFalse(uploader.hasPendingLocalAccountDeletion(ownerID: "owner-a"))
        XCTAssertTrue(try store.loadRecordings().isEmpty)
    }

    private func simulatedCAF(at url: URL) throws {
        func chunk(_ type: String, payload: Data) -> Data {
            let size = UInt64(payload.count)
            var data = Data(type.utf8)
            data.append(contentsOf: (0..<8).reversed().map {
                UInt8((size >> UInt64($0 * 8)) & 0xff)
            })
            data.append(payload)
            return data
        }
        var description = Data(count: 32)
        description.replaceSubrange(8..<12, with: Data("lpcm".utf8))
        try (Data("caff".utf8) + Data([0x00, 0x01, 0x00, 0x00])
            + chunk("desc", payload: description)
            + chunk("data", payload: Data([0, 0, 0, 0, 1, 0]))).write(to: url)
    }
}

final class NotificationRouteTests: XCTestCase {
    func testAudioNotificationOpensTheAudioItem() {
        XCTAssertEqual(
            NotificationRouter.reference(from: ["item_id": "abc", "type": "audio"]),
            LibraryReference(itemType: "audio", itemId: "abc")
        )
    }

    func testNotificationFromAnOlderBuildOpensAsATranscript() {
        XCTAssertEqual(
            NotificationRouter.reference(from: ["item_id": "abc"]),
            LibraryReference(itemType: "transcript", itemId: "abc")
        )
    }

    func testMalformedNotificationsAreIgnored() {
        XCTAssertNil(NotificationRouter.reference(from: [:]))
        XCTAssertNil(NotificationRouter.reference(from: ["item_id": ""]))
        XCTAssertNil(NotificationRouter.reference(from: ["item_id": "abc", "type": "unknown"]))
    }

    @MainActor
    func testRouteWaitsForTheFirstViewAndIsConsumedOnce() {
        let router = NotificationRouter()
        let reference = LibraryReference(itemType: "audio", itemId: "abc")

        router.open(reference)

        XCTAssertEqual(router.consume(), reference)
        XCTAssertNil(router.consume())
    }
}

@MainActor
final class LibraryFreshnessTests: XCTestCase {
    private func sample(_ id: String, status: String = "completed", archived: Bool = false) -> LibraryListItem {
        LibraryListItem(
            id: id, itemType: "audio", title: id, subtitle: "", status: status,
            wordCount: 1, duration: 1, pageCount: 0, summaryStatus: "", favorite: false,
            archived: archived, tags: [], createdAt: Date()
        )
    }

    func testAutomaticRefreshIsThrottledButKnownChangesAreNot() async {
        var clock = Date(timeIntervalSince1970: 1_000)
        var requests = 0
        let item = sample("a")
        let model = LibraryViewModel(now: { clock }, loadPage: { _, _ in
            requests += 1
            return LibraryListResponse(data: [item], page: 1, perPage: 20, totalItems: 1, totalPages: 1)
        })
        await model.loadIfNeeded(for: model.query)
        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(requests, 1)

        await model.refreshIfStale()
        XCTAssertEqual(requests, 1, "A second glance inside the window stays cached")

        clock.addTimeInterval(LibraryViewModel.minimumAutomaticRefreshInterval + 1)
        await model.refreshIfStale()
        XCTAssertEqual(requests, 2)

        await model.refresh()
        XCTAssertEqual(requests, 3, "An upload changing state always refreshes")
    }

    func testRefreshIfStaleDoesNotRunBeforeTheFirstLoad() async {
        let model = LibraryViewModel(previewItems: [sample("a")])
        await model.refreshIfStale()
        XCTAssertTrue(model.items.isEmpty)
    }

    func testActiveItemsAreDetected() async {
        let model = LibraryViewModel(previewItems: [sample("a"), sample("b", status: "processing")])
        await model.loadIfNeeded(for: model.query)
        XCTAssertTrue(model.hasActiveItems)

        let settled = LibraryViewModel(previewItems: [sample("a")])
        await settled.loadIfNeeded(for: settled.query)
        XCTAssertFalse(settled.hasActiveItems)
    }

    func testArchivedItemsAreSeparateAndReachable() async {
        let model = LibraryViewModel(previewItems: [sample("kept"), sample("old", archived: true)])
        await model.loadIfNeeded(for: model.query)
        XCTAssertEqual(model.items.map(\.id), ["kept"])

        model.showsArchived = true
        await model.loadIfNeeded(for: model.query)
        XCTAssertEqual(model.items.map(\.id), ["old"])
    }

    func testArchivePathUsesTheServerParameter() {
        let path = MediaToolsService.libraryItemsPath(
            page: 1, perPage: 20, itemType: nil, status: nil, search: nil,
            sortDirection: "desc", archivedOnly: true
        )
        XCTAssertTrue(path.contains("archive=only"), path)
        XCTAssertFalse(
            MediaToolsService.libraryItemsPath(
                page: 1, perPage: 20, itemType: nil, status: nil, search: nil, sortDirection: "desc"
            ).contains("archive")
        )
    }
}
