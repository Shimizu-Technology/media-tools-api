import XCTest
@testable import MediaTools

/// Stops every upload at the first network request, which is enough to prove a
/// recording was sent with no taps while its audio stays on the device.
@MainActor
private final class RecordingServiceSpy: RecordingUploadServicing {
    private(set) var presignedFilenames: [String] = []
    private(set) var importedLinks: [String] = []
    private(set) var importedPDFs: [String] = []
    var documentImportError: Error?

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
        if let documentImportError { throw documentImportError }
        importedLinks.append(link)
    }

    func importSharedPDF(fileURL: URL, filename: String, expectedOwnerID: String?) async throws {
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

        uploader.processSharedItems(retryRejected: true)
        await settle { !service.importedLinks.isEmpty }
        XCTAssertEqual(service.importedLinks, ["https://example.com/article"])
    }

    func testRemovingAShareIsTheOnlyWayItLeavesTheInboxUnprocessed() async throws {
        await signIn()
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
        let model = LibraryViewModel(previewItems: [sample("a")], now: { clock })
        await model.loadIfNeeded(for: model.query)
        XCTAssertEqual(model.items.count, 1)
        model.remove([model.items[0].reference])
        XCTAssertTrue(model.items.isEmpty)

        await model.refreshIfStale()
        XCTAssertTrue(model.items.isEmpty, "A second glance inside the window stays cached")

        clock.addTimeInterval(LibraryViewModel.minimumAutomaticRefreshInterval + 1)
        await model.refreshIfStale()
        XCTAssertEqual(model.items.count, 1)

        model.remove([model.items[0].reference])
        await model.refresh()
        XCTAssertEqual(model.items.count, 1, "An upload changing state always refreshes")
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

    func testPresentedReferenceSurvivesWithoutTheLibraryViewOnScreen() {
        let model = LibraryViewModel(previewItems: [])
        let reference = LibraryReference(itemType: "audio", itemId: "abc")
        model.presentedReference = reference
        XCTAssertEqual(model.presentedReference, reference)
    }
}
