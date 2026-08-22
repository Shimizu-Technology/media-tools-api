import XCTest
@testable import MediaTools

final class ModelDecodingTests: XCTestCase {
    func testPublicComplianceURLsUseTheConfiguredWebApp() {
        XCTAssertEqual(Configuration.privacyURL.absoluteString, "\(Configuration.webAppURL)/privacy")
        XCTAssertEqual(Configuration.termsURL.absoluteString, "\(Configuration.webAppURL)/terms")
        XCTAssertEqual(Configuration.supportURL.absoluteString, "\(Configuration.webAppURL)/support")
        XCTAssertEqual(
            Configuration.accountDeletionURL.absoluteString,
            "\(Configuration.webAppURL)/delete-account"
        )
    }

    @MainActor
    func testAIProcessingConsentIsExplicitAccountScopedAndRevocable() async {
        let suiteName = "AIProcessingConsentTests.\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = AIProcessingConsentManager(defaults: defaults)
        manager.setActiveOwnerID("owner-a")
        XCTAssertFalse(manager.hasConsent)

        let request = Task { await manager.requestPermission() }
        await Task.yield()
        XCTAssertTrue(manager.isPresentingDisclosure)
        manager.allow()
        let granted = await request.value
        XCTAssertTrue(granted)
        XCTAssertTrue(manager.hasConsent)

        manager.setActiveOwnerID("owner-b")
        XCTAssertFalse(manager.hasConsent, "permission must not leak between accounts")
        XCTAssertTrue(manager.hasConsent(ownerID: "owner-a"))
        manager.setActiveOwnerID("owner-a")
        XCTAssertTrue(manager.hasConsent)

        manager.revoke()
        XCTAssertFalse(manager.hasConsent)
    }

    @MainActor
    func testAIProcessingConsentDeclineLeavesRequestBlocked() async {
        let suiteName = "AIProcessingConsentTests.\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = AIProcessingConsentManager(defaults: defaults)
        manager.setActiveOwnerID("owner-a")
        let request = Task { await manager.requestPermission() }
        await Task.yield()
        manager.decline()

        let granted = await request.value
        XCTAssertFalse(granted)
        XCTAssertFalse(manager.hasConsent)
        XCTAssertFalse(manager.isPresentingDisclosure)
    }

    private func mediaBox(_ type: String, payload: Data) -> Data {
        let size = UInt32(payload.count + 8)
        var data = Data([
            UInt8((size >> 24) & 0xff), UInt8((size >> 16) & 0xff),
            UInt8((size >> 8) & 0xff), UInt8(size & 0xff),
        ])
        data.append(Data(type.utf8))
        data.append(payload)
        return data
    }

    private func finalizedM4AData() -> Data {
        mediaBox("ftyp", payload: Data("M4A ".utf8))
            + mediaBox("mdat", payload: Data([0x01, 0x02]))
            + mediaBox("moov", payload: Data([0x03]))
    }

    private func unfinalizedM4AData() -> Data {
        mediaBox("ftyp", payload: Data("M4A ".utf8))
            + mediaBox("mdat", payload: Data([0x01, 0x02]))
    }

    private func cafData(unknownDataLength: Bool) -> Data {
        func chunk(_ type: String, payload: Data, unknownLength: Bool = false) -> Data {
            let size = unknownLength ? UInt64.max : UInt64(payload.count)
            var data = Data(type.utf8)
            data.append(contentsOf: (0..<8).reversed().map {
                UInt8((size >> UInt64($0 * 8)) & 0xff)
            })
            data.append(payload)
            return data
        }

        var description = Data(count: 32)
        description.replaceSubrange(8..<12, with: Data("lpcm".utf8))
        return Data("caff".utf8) + Data([0x00, 0x01, 0x00, 0x00])
            + chunk("desc", payload: description)
            + chunk(
                "data",
                payload: Data([0, 0, 0, 0, 1, 0, 2, 0]),
                unknownLength: unknownDataLength
            )
    }

    @MainActor
    func testQuickCaptureNavigationSurvivesUntilMainTabsConsumeIt() {
        // Clear any state left by a previous interrupted test run.
        _ = QuickCaptureNavigation.consumeRecordTabRequest()

        QuickCaptureNavigation.requestRecordTab()

        XCTAssertTrue(QuickCaptureNavigation.consumeRecordTabRequest())
        XCTAssertFalse(QuickCaptureNavigation.consumeRecordTabRequest())
    }

    @MainActor
    func testTranscriptionWatchRetryDelayIsPositiveAndCapped() {
        XCTAssertEqual(RecordingUploadCoordinator.watchRetryDelay(after: 0), .seconds(5))
        XCTAssertEqual(RecordingUploadCoordinator.watchRetryDelay(after: 3), .seconds(15))
        XCTAssertEqual(RecordingUploadCoordinator.watchRetryDelay(after: 100), .seconds(60))
    }

    @MainActor
    func testTranscriptionWatchClassifiesTransientAuthenticationAndPermanentFailures() {
        XCTAssertEqual(
            RecordingUploadCoordinator.watchFailureDisposition(
                for: URLError(.notConnectedToInternet)
            ),
            .retry
        )
        XCTAssertEqual(
            RecordingUploadCoordinator.watchFailureDisposition(
                for: APIError.httpError(statusCode: 503, message: "Unavailable")
            ),
            .retry
        )
        XCTAssertEqual(
            RecordingUploadCoordinator.watchFailureDisposition(
                for: APIError.httpError(statusCode: 401, message: "Sign in")
            ),
            .pauseForAuthentication
        )
        XCTAssertEqual(
            RecordingUploadCoordinator.watchFailureDisposition(
                for: APIError.authenticationRequired(message: "Restoring sign-in")
            ),
            .pauseForAuthentication
        )
        XCTAssertEqual(
            RecordingUploadCoordinator.watchFailureDisposition(
                for: APIError.httpError(statusCode: 404, message: "Missing")
            ),
            .stop
        )
        XCTAssertEqual(
            RecordingUploadCoordinator.watchFailureDisposition(
                for: APIError.httpError(statusCode: 403, message: "Forbidden")
            ),
            .stop
        )
        XCTAssertEqual(
            RecordingUploadCoordinator.watchFailureDisposition(
                for: DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "Malformed response")
                )
            ),
            .stop
        )
    }

    @MainActor
    func testRecordingUploadsPauseInsteadOfRetryingAuthenticationFailures() {
        XCTAssertTrue(
            RecordingUploadCoordinator.isAuthenticationFailure(
                APIError.authenticationRequired(message: "Sign in")
            )
        )
        XCTAssertTrue(
            RecordingUploadCoordinator.isAuthenticationFailure(
                APIError.httpError(statusCode: 401, message: "Expired")
            )
        )
        XCTAssertFalse(
            RecordingUploadCoordinator.isAuthenticationFailure(
                APIError.httpError(statusCode: 503, message: "Unavailable")
            )
        )
        XCTAssertFalse(
            RecordingUploadCoordinator.isAuthenticationFailure(
                APIError.authenticationTemporarilyUnavailable(message: "Clerk unavailable")
            )
        )
    }

    @MainActor
    func testAuthenticationPauseStartsAtFirstFailureAndSurvivesViewActivations() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let oldWatch = TranscriptionWatch(
            id: "old",
            title: "Old recording",
            createdAt: now.addingTimeInterval(-10 * 365 * 24 * 60 * 60),
            authenticationPausedAt: nil
        )
        let paused = RecordingUploadCoordinator.markingAuthenticationPaused(
            oldWatch,
            now: now
        )
        let unchangedOnNextActivation = RecordingUploadCoordinator.markingAuthenticationPaused(
            paused,
            now: now.addingTimeInterval(60)
        )

        XCTAssertFalse(
            RecordingUploadCoordinator.authenticationPauseHasExpired(oldWatch, now: now)
        )
        XCTAssertEqual(paused.authenticationPausedAt, now)
        XCTAssertEqual(unchangedOnNextActivation.authenticationPausedAt, now)
        XCTAssertFalse(
            RecordingUploadCoordinator.authenticationPauseHasExpired(paused, now: now)
        )
        XCTAssertTrue(
            RecordingUploadCoordinator.authenticationPauseHasExpired(
                paused,
                now: now.addingTimeInterval(
                    RecordingUploadCoordinator.maximumAuthenticationPauseAge
                )
            )
        )
    }

    private struct DatedPayload: Decodable {
        let createdAt: Date
    }

    func testHealthResponseDecodesHealthyDatabaseState() throws {
        let data = Data(#"{"status":"ok","version":"1.0.0","database":"healthy","workers":3,"yt_dlp_cookies_configured":true}"#.utf8)
        let health = try JSONDecoder().decode(HealthResponse.self, from: data)

        XCTAssertEqual(health.status, "ok")
        XCTAssertEqual(health.database, "healthy")
        XCTAssertEqual(health.workers, 3)
    }

    func testAPIDecoderAcceptsGoDatesWithAndWithoutFractionalSeconds() throws {
        let fractional = Data(#"{"created_at":"2026-02-20T00:33:45.123Z"}"#.utf8)
        let whole = Data(#"{"created_at":"2026-02-20T00:33:45Z"}"#.utf8)
        let decoder = APIClient.makeDecoder()

        let fractionalPayload = try decoder.decode(DatedPayload.self, from: fractional)
        let wholePayload = try decoder.decode(DatedPayload.self, from: whole)

        XCTAssertEqual(
            fractionalPayload.createdAt.timeIntervalSince(wholePayload.createdAt),
            0.123,
            accuracy: 0.001
        )
    }

    func testHostApplicationHasInstallableBundleMetadata() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.ShimizuTechnology.MediaTools")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundlePackageType") as? String, "APPL")
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable"))
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion"))
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "UILaunchScreen"))
        XCTAssertTrue(
            (Bundle.main.object(forInfoDictionaryKey: "UISupportedInterfaceOrientations") as? [String])?
                .contains("UIInterfaceOrientationPortrait") == true
        )
    }

    func testHostApplicationDeclaresBackgroundAudioForUserInitiatedRecording() throws {
        let modes = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        )
        XCTAssertEqual(modes, ["audio"])
    }

    func testHostApplicationDeclaresLiveActivitiesAndRecordingDeepLink() throws {
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "NSSupportsLiveActivities") as? Bool,
            true
        )

        let urlTypes = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes")
                as? [[String: Any]]
        )
        let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(schemes.contains("mediatools"))
    }

    func testHostApplicationDeclaresPrivacyAndExportComplianceMetadata() throws {
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption") as? Bool,
            false
        )
        let microphonePurpose = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
        )
        XCTAssertTrue(microphonePurpose.contains("only after you start a recording"))

        let manifestURL = try XCTUnwrap(
            Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
        )
        let data = try Data(contentsOf: manifestURL)
        let manifest = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)

        let accessed = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var reasons: [String: [String]] = [:]
        for entry in accessed {
            guard let category = entry["NSPrivacyAccessedAPIType"] as? String,
                  let values = entry["NSPrivacyAccessedAPITypeReasons"] as? [String]
            else { continue }
            reasons[category] = values
        }
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategoryUserDefaults"], ["CA92.1"])
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategoryDiskSpace"], ["E174.1"])
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategoryFileTimestamp"], ["C617.1"])
    }

    @MainActor
    func testRecordingCoordinatorRejectsAndPreservesUnfinalizedInterruptedCapture() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try RecordingStore(rootDirectory: directory)
        let id = UUID()
        var recording = LocalRecording(
            id: id,
            filename: "\(id.uuidString.lowercased()).m4a",
            originalFilename: "Legacy recording.m4a",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 0,
            contentType: "meeting",
            state: .recording,
            lastError: nil,
            uploadProgress: nil,
            uploadObjectKey: nil,
            uploadSizeBytes: nil,
            uploadMimeType: nil,
            uploadTaskIdentifier: nil
        )
        recording.duration = 37
        try unfinalizedM4AData().write(to: store.fileURL(for: recording))
        try store.saveRecordings([recording])

        let coordinator = RecordingCoordinator(store: store)
        let recovered = try XCTUnwrap(coordinator.pendingRecordings.first)

        XCTAssertEqual(recovered.id, recording.id)
        XCTAssertEqual(recovered.contentType, "meeting")
        XCTAssertEqual(recovered.duration, 37)
        XCTAssertEqual(recovered.state, .invalid)
        XCTAssertTrue(recovered.lastError?.contains("best-effort recovery") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: recording).path))

        let reloaded = try XCTUnwrap(store.loadRecordings().first)
        XCTAssertEqual(reloaded.state, .invalid)
    }

    @MainActor
    func testRecordingCoordinatorRecoversOnlyVerifiedInterruptedCapture() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try RecordingStore(rootDirectory: directory)
        var recording = store.makeRecording(contentType: "meeting")
        recording.duration = 37
        try cafData(unknownDataLength: false).write(to: store.fileURL(for: recording))
        try store.saveRecordings([recording])

        let coordinator = RecordingCoordinator(store: store)
        let recovered = try XCTUnwrap(coordinator.pendingRecordings.first)

        XCTAssertEqual(recovered.state, .interrupted)
        XCTAssertTrue(recovered.canUpload)
        XCTAssertTrue(recovered.lastError?.contains("verified") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: recording).path))
    }

    func testRecordingIntegrityValidatorRequiresMovieMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let validURL = directory.appendingPathComponent("valid.m4a")
        let invalidURL = directory.appendingPathComponent("invalid.m4a")
        try finalizedM4AData().write(to: validURL)
        try unfinalizedM4AData().write(to: invalidURL)

        XCTAssertNoThrow(try RecordingIntegrityValidator.validate(url: validURL).get())
        XCTAssertThrowsError(try RecordingIntegrityValidator.validate(url: invalidURL).get()) { error in
            XCTAssertEqual(error as? RecordingIntegrityError, .unfinalizedContainer)
        }
    }

    func testRecordingStoreCreatesCrashRecoverableCAF() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try RecordingStore(rootDirectory: directory)
        let recording = store.makeRecording(contentType: "voice_memo")

        XCTAssertEqual((recording.filename as NSString).pathExtension, "caf")
        XCTAssertEqual(((recording.originalFilename ?? "") as NSString).pathExtension, "caf")
    }

    func testRecordingIntegrityValidatorAcceptsCAFWithUnknownDataLength() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let interruptedURL = directory.appendingPathComponent("interrupted.caf")
        try cafData(unknownDataLength: true).write(to: interruptedURL)

        XCTAssertNoThrow(try RecordingIntegrityValidator.validate(url: interruptedURL).get())
    }

    @MainActor
    func testCAFUploadUsesExplicitAudioMIMEType() {
        XCTAssertEqual(
            RecordingUploadCoordinator.mimeType(for: URL(fileURLWithPath: "/tmp/recording.caf")),
            "audio/x-caf"
        )
    }

    @MainActor
    func testRecordingCoordinatorRecoversInterruptedCAFForUpload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try RecordingStore(rootDirectory: directory)
        var recording = store.makeRecording(contentType: "meeting")
        recording.duration = 28
        try cafData(unknownDataLength: true).write(to: store.fileURL(for: recording))
        try store.saveRecordings([recording])

        let coordinator = RecordingCoordinator(store: store)
        let recovered = try XCTUnwrap(coordinator.pendingRecordings.first)

        XCTAssertEqual(recovered.state, .interrupted)
        XCTAssertTrue(recovered.canUpload)
        XCTAssertEqual((recovered.uploadFilename as NSString).pathExtension, "caf")
    }

    func testLocalRecordingDecodesManifestWrittenBeforeServerRetentionFields() throws {
        let data = Data(
            #"{"id":"11111111-1111-1111-1111-111111111111","filename":"memo.m4a","createdAt":"2026-08-21T03:00:00Z","duration":12,"contentType":"voice_memo","state":"ready"}"#.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let recording = try decoder.decode(LocalRecording.self, from: data)

        XCTAssertEqual(recording.state, .ready)
        XCTAssertNil(recording.remoteTranscriptionID)
        XCTAssertNil(recording.ownerID)
    }

    @MainActor
    func testDeviceRecordingsAreClaimedAndIsolatedByClerkOwner() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try RecordingStore(rootDirectory: directory)
        var legacy = store.makeRecording(contentType: "voice_memo")
        legacy.state = .ready
        var other = store.makeRecording(contentType: "meeting", ownerID: "user_other")
        other.state = .ready
        try cafData(unknownDataLength: true).write(to: store.fileURL(for: legacy))
        try cafData(unknownDataLength: true).write(to: store.fileURL(for: other))
        try store.saveRecordings([legacy, other])

        let coordinator = RecordingCoordinator(store: store)
        coordinator.setActiveOwnerID("user_current")

        XCTAssertEqual(coordinator.availableRecordings.map(\.id), [legacy.id])
        XCTAssertEqual(coordinator.recording(withID: legacy.id)?.ownerID, "user_current")
        XCTAssertEqual(try store.loadRecordings().first(where: { $0.id == legacy.id })?.ownerID, "user_current")

        coordinator.setActiveOwnerID("user_other")
        XCTAssertEqual(coordinator.availableRecordings.map(\.id), [other.id])

        try coordinator.deleteRecordingsOwned(by: "user_current")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(for: legacy).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: other).path))
        XCTAssertEqual(coordinator.pendingRecordings.map(\.id), [other.id])
    }

    @MainActor
    func testInterruptedLegacyOwnerClaimCannotMoveToAnotherAccount() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let defaultsSuite = "MediaToolsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer {
            defaults.removePersistentDomain(forName: defaultsSuite)
            try? FileManager.default.removeItem(at: directory)
        }

        let store = try RecordingStore(rootDirectory: directory)
        var legacy = store.makeRecording(contentType: "voice_memo")
        legacy.state = .ready
        try cafData(unknownDataLength: true).write(to: store.fileURL(for: legacy))
        try store.saveRecordings([legacy])
        defaults.set(
            "user_original",
            forKey: RecordingCoordinator.pendingLegacyRecordingOwnerIDKey
        )

        let coordinator = RecordingCoordinator(
            store: store,
            localAccountDefaults: defaults
        )
        coordinator.setActiveOwnerID("user_new")

        XCTAssertEqual(coordinator.recording(withID: legacy.id)?.ownerID, "user_original")
        XCTAssertTrue(coordinator.availableRecordings.isEmpty)
        XCTAssertEqual(
            try store.loadRecordings().first?.ownerID,
            "user_original"
        )
        XCTAssertNil(defaults.string(forKey: RecordingCoordinator.pendingLegacyRecordingOwnerIDKey))
    }

    @MainActor
    func testPendingDeletedAccountCleanupRetriesBeforeAnotherOwnerActivates() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let defaultsSuite = "MediaToolsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer {
            defaults.removePersistentDomain(forName: defaultsSuite)
            try? FileManager.default.removeItem(at: directory)
        }

        let store = try RecordingStore(rootDirectory: directory)
        var deletedOwnerRecording = store.makeRecording(
            contentType: "voice_memo",
            ownerID: "user_deleted"
        )
        deletedOwnerRecording.state = .ready
        let audioURL = store.fileURL(for: deletedOwnerRecording)
        try cafData(unknownDataLength: true).write(to: audioURL)
        try store.saveRecordings([deletedOwnerRecording])
        defaults.set(
            ["user_deleted"],
            forKey: RecordingUploadCoordinator.pendingLocalAccountDeletionOwnerIDsKey
        )

        let recorder = RecordingCoordinator(store: store)
        let watchStore = try TranscriptionWatchStore(rootDirectory: directory)
        let uploader = RecordingUploadCoordinator(
            recorder: recorder,
            watchStore: watchStore,
            localAccountDefaults: defaults
        )

        await uploader.setActiveOwnerID("user_new")

        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertFalse(uploader.hasPendingLocalAccountDeletion(ownerID: "user_deleted"))
        XCTAssertTrue(recorder.pendingRecordings.isEmpty)
        XCTAssertEqual(recorder.activeOwnerID, "user_new")
    }

    @MainActor
    func testDelayedFinalizationCannotCrossAnAccountSwitch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try RecordingStore(rootDirectory: directory)
        var recording = store.makeRecording(contentType: "meeting", ownerID: "user_original")
        recording.state = .ready
        try finalizedM4AData().write(to: store.fileURL(for: recording))
        try store.saveRecordings([recording])
        let recorder = RecordingCoordinator(store: store)
        recorder.setActiveOwnerID("user_original")
        recorder.markWaitingForUpload(recording.id)
        recorder.markUploadStarted(
            recording.id,
            objectKey: "audio/original/meeting.m4a",
            sizeBytes: 42,
            mimeType: "audio/mp4",
            taskIdentifier: 17
        )
        recorder.markUploadFinalizing(recording.id)

        let service = SuspendedRecordingUploadService()
        let consentSuite = "AIProcessingConsentTests.\(UUID().uuidString)"
        let consentDefaults = try XCTUnwrap(UserDefaults(suiteName: consentSuite))
        defer { consentDefaults.removePersistentDomain(forName: consentSuite) }
        let consent = AIProcessingConsentManager(defaults: consentDefaults)
        consent.setActiveOwnerID("user_original")
        consent.allow()
        let uploader = RecordingUploadCoordinator(
            recorder: recorder,
            service: service,
            watchStore: try TranscriptionWatchStore(rootDirectory: directory),
            aiProcessingConsent: consent
        )
        await uploader.setActiveOwnerID("user_original")
        for _ in 0..<20 where !service.completeStarted {
            await Task.yield()
        }
        XCTAssertTrue(service.completeStarted)
        XCTAssertEqual(service.completionOwnerIDs, ["user_original"])

        await uploader.setActiveOwnerID("user_new")
        service.resumeCompletion(
            try APIClient.makeDecoder().decode(
                AudioTranscription.self,
                from: Data(#"{"id":"audio-cross-account","status":"pending"}"#.utf8)
            )
        )
        await Task.yield()

        XCTAssertEqual(recorder.activeOwnerID, "user_new")
        XCTAssertEqual(
            recorder.recording(withID: recording.id)?.state,
            .finalizingUpload
        )
        XCTAssertNil(recorder.recording(withID: recording.id)?.remoteTranscriptionID)
        XCTAssertNil(uploader.latestItem)
        XCTAssertEqual(service.completionOwnerIDs, ["user_original"])
    }

    @MainActor
    func testPendingFinalizationWaitsForExplicitAIConsent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let consentSuite = "AIProcessingConsentTests.\(UUID().uuidString)"
        let consentDefaults = try XCTUnwrap(UserDefaults(suiteName: consentSuite))
        defer {
            consentDefaults.removePersistentDomain(forName: consentSuite)
            try? FileManager.default.removeItem(at: directory)
        }

        let store = try RecordingStore(rootDirectory: directory)
        var recording = store.makeRecording(contentType: "meeting", ownerID: "user_current")
        recording.state = .ready
        try finalizedM4AData().write(to: store.fileURL(for: recording))
        try store.saveRecordings([recording])
        let recorder = RecordingCoordinator(store: store)
        recorder.setActiveOwnerID("user_current")
        recorder.markWaitingForUpload(recording.id)
        recorder.markUploadStarted(
            recording.id,
            objectKey: "audio/current/meeting.m4a",
            sizeBytes: 42,
            mimeType: "audio/mp4",
            taskIdentifier: 19
        )
        recorder.markUploadFinalizing(recording.id)

        let consent = AIProcessingConsentManager(defaults: consentDefaults)
        consent.setActiveOwnerID("user_current")
        let service = SuspendedRecordingUploadService()
        let uploader = RecordingUploadCoordinator(
            recorder: recorder,
            service: service,
            watchStore: try TranscriptionWatchStore(rootDirectory: directory),
            aiProcessingConsent: consent
        )

        await uploader.setActiveOwnerID("user_current")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(service.completeStarted)
        XCTAssertEqual(recorder.recording(withID: recording.id)?.state, .finalizingUpload)

        consent.allow()
        uploader.resumePendingWork()
        for _ in 0..<20 where !service.completeStarted { await Task.yield() }
        XCTAssertTrue(service.completeStarted)
        XCTAssertEqual(service.completionOwnerIDs, ["user_current"])

        service.resumeCompletion(
            try APIClient.makeDecoder().decode(
                AudioTranscription.self,
                from: Data(#"{"id":"audio-after-consent","status":"pending"}"#.utf8)
            )
        )
        await Task.yield()
    }

    @MainActor
    func testDelayedBackgroundCompletionIsIgnoredForAnotherOwner() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try RecordingStore(rootDirectory: directory)
        var recording = store.makeRecording(contentType: "meeting", ownerID: "user_original")
        recording.state = .ready
        try finalizedM4AData().write(to: store.fileURL(for: recording))
        try store.saveRecordings([recording])
        let recorder = RecordingCoordinator(store: store)
        recorder.setActiveOwnerID("user_original")
        recorder.markWaitingForUpload(recording.id)
        recorder.markUploadStarted(
            recording.id,
            objectKey: "audio/original/meeting.m4a",
            sizeBytes: 42,
            mimeType: "audio/mp4",
            taskIdentifier: 18
        )
        let uploader = RecordingUploadCoordinator(
            recorder: recorder,
            service: SuspendedRecordingUploadService(),
            watchStore: try TranscriptionWatchStore(rootDirectory: directory)
        )

        await uploader.setActiveOwnerID("user_new")
        uploader.receiveBackgroundUploadEvent(
            .completed(
                metadata: BackgroundUploadMetadata(
                    recordingID: recording.id,
                    ownerID: "user_original",
                    filename: recording.uploadFilename,
                    objectKey: "audio/original/meeting.m4a",
                    sizeBytes: 42,
                    mimeType: "audio/mp4",
                    contentType: recording.contentType
                )
            )
        )

        XCTAssertEqual(recorder.recording(withID: recording.id)?.state, .uploading)
        XCTAssertNil(recorder.recording(withID: recording.id)?.remoteTranscriptionID)
    }

    @MainActor
    func testDiscardingLocalRecordingDeletesAudioAndManifestEntry() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try RecordingStore(rootDirectory: directory)
        var recording = store.makeRecording(contentType: "voice_memo")
        recording.state = .ready
        let audioURL = store.fileURL(for: recording)
        try Data([0xAA, 0xBB]).write(to: audioURL)
        try store.saveRecordings([recording])

        let coordinator = RecordingCoordinator(store: store)
        coordinator.discard(recording)

        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(coordinator.pendingRecordings.isEmpty)
        XCTAssertTrue(try store.loadRecordings().isEmpty)
    }

    @MainActor
    func testSimulatedCaptureExercisesDurableStartAndStopState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try RecordingStore(rootDirectory: directory)
        let coordinator = RecordingCoordinator(store: store, simulatesCapture: true)

        coordinator.start(contentType: "phone_call")
        XCTAssertTrue(coordinator.isRecording)
        XCTAssertTrue(coordinator.availableRecordings.isEmpty)

        coordinator.stop()
        XCTAssertEqual(coordinator.duration, 0)
        XCTAssertEqual(coordinator.formattedDuration, "00:00")
        let saved = try XCTUnwrap(coordinator.availableRecordings.first)
        XCTAssertEqual(saved.contentType, "phone_call")
        XCTAssertEqual(saved.state, .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: saved).path))
        let reloaded = try XCTUnwrap(store.loadRecordings().first)
        XCTAssertEqual(reloaded.id, saved.id)
        XCTAssertEqual(reloaded.contentType, saved.contentType)
        XCTAssertEqual(reloaded.state, saved.state)
        XCTAssertEqual(reloaded.duration, saved.duration)
        XCTAssertTrue(saved.displayTitle.hasPrefix("Recording — "))
        XCTAssertFalse(saved.uploadFilename.contains(saved.id.uuidString.lowercased()))
    }

    @MainActor
    func testSimulatedCapturePausesResumesAndStopsFromPausedState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let activityManager = TestRecordingActivityManager()
        let store = try RecordingStore(rootDirectory: directory)
        let coordinator = RecordingCoordinator(
            store: store,
            simulatesCapture: true,
            activityManager: activityManager
        )

        coordinator.start(contentType: "meeting")
        XCTAssertEqual(coordinator.captureState, .recording)
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertTrue(coordinator.pause())
        XCTAssertTrue(coordinator.isRecording)
        XCTAssertTrue(coordinator.isPaused)
        XCTAssertEqual(coordinator.statusMessage, "Recording paused")
        let pausedDuration = coordinator.duration
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(coordinator.duration, pausedDuration, accuracy: 0.001)
        await Task.yield()
        XCTAssertEqual(activityManager.updates.last?.isPaused, true)
        XCTAssertEqual(activityManager.updates.last?.isInterrupted, false)

        XCTAssertTrue(coordinator.resume())
        XCTAssertEqual(coordinator.captureState, .recording)
        XCTAssertEqual(coordinator.statusMessage, "Recording resumed")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertGreaterThan(coordinator.duration, pausedDuration)
        await Task.yield()
        XCTAssertEqual(activityManager.updates.last?.isPaused, false)
        XCTAssertEqual(activityManager.updates.last?.isInterrupted, false)

        XCTAssertTrue(coordinator.pause())
        coordinator.stop()

        XCTAssertEqual(coordinator.captureState, .idle)
        let saved = try XCTUnwrap(coordinator.availableRecordings.first)
        XCTAssertEqual(saved.state, .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: saved).path))
    }

    func testRecordingActivityStateDecodesBeforePauseSupport() throws {
        let data = Data(
            #"{"elapsedDuration":12,"resumedAt":null,"isInterrupted":true}"#.utf8
        )

        let state = try JSONDecoder().decode(
            RecordingActivityAttributes.ContentState.self,
            from: data
        )

        XCTAssertEqual(state.elapsedDuration, 12)
        XCTAssertFalse(state.isPaused)
        XCTAssertTrue(state.isInterrupted)
    }

    func testLibraryPreferencePatchOmitsUnchangedFields() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(UpdateLibraryPreferencesRequest(favorite: true))
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(payload["favorite"] as? Bool, true)
        XCTAssertNil(payload["archived"])
        XCTAssertNil(payload["tags"])
    }

    func testRenameAudioRequestUsesBackendContract() throws {
        let data = try JSONEncoder().encode(RenameAudioRequest(name: "Client discovery"))
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: String]
        )
        XCTAssertEqual(payload, ["name": "Client discovery"])
    }

    @MainActor
    func testRecordingDoesNotStartWhenStorageIsAlreadyLow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let coordinator = RecordingCoordinator(
            store: try RecordingStore(rootDirectory: directory),
            simulatesCapture: true,
            availableCapacity: { _ in RecordingCoordinator.minimumStartCapacityBytes - 1 }
        )

        coordinator.start(contentType: "meeting")

        XCTAssertFalse(coordinator.isRecording)
        XCTAssertTrue(coordinator.pendingRecordings.isEmpty)
        XCTAssertTrue(coordinator.storageIsLow)
        XCTAssertEqual(
            coordinator.errorMessage,
            "Free at least 100 MB of storage before starting a recording."
        )
    }

    @MainActor
    func testLongRecordingStopsSafelyBeforeStorageIsExhausted() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var bytesAvailable = RecordingCoordinator.minimumStartCapacityBytes
        let store = try RecordingStore(rootDirectory: directory)
        let coordinator = RecordingCoordinator(
            store: store,
            simulatesCapture: true,
            availableCapacity: { _ in bytesAvailable }
        )

        coordinator.start(contentType: "lecture")
        XCTAssertTrue(coordinator.isRecording)
        bytesAvailable = RecordingCoordinator.criticalRecordingCapacityBytes - 1
        coordinator.enforceStorageSafetyIfNeeded(force: true)

        XCTAssertFalse(coordinator.isRecording)
        XCTAssertTrue(coordinator.storageIsLow)
        let saved = try XCTUnwrap(coordinator.availableRecordings.first)
        XCTAssertEqual(saved.state, .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: saved).path))
        XCTAssertEqual(
            coordinator.statusMessage,
            "Recording stopped and saved because this iPhone is low on storage."
        )
    }

    func testRecordingManifestMigratesEntriesWithoutUploadMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let id = UUID()
        let filename = "\(id.uuidString.lowercased()).m4a"
        try Data([0x01]).write(to: directory.appendingPathComponent(filename))
        let manifest = """
            {
              "version": 1,
              "recordings": [{
                "id": "\(id.uuidString)",
                "filename": "\(filename)",
                "createdAt": "2026-08-19T00:00:00Z",
                "duration": 12,
                "contentType": "voice_memo",
                "state": "ready"
              }]
            }
            """
        try Data(manifest.utf8).write(to: directory.appendingPathComponent("recordings.json"))

        let restored = try XCTUnwrap(
            RecordingStore(rootDirectory: directory).loadRecordings().first
        )
        XCTAssertEqual(restored.id, id)
        XCTAssertEqual(restored.state, .ready)
        XCTAssertNil(restored.uploadObjectKey)
        XCTAssertNil(restored.uploadProgress)
    }

    @MainActor
    func testUploadTransitionsPersistProgressAndFinalizationMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try RecordingStore(rootDirectory: directory)
        var recording = store.makeRecording(contentType: "meeting")
        recording.state = .ready
        try Data([0x01, 0x02]).write(to: store.fileURL(for: recording))
        try store.saveRecordings([recording])
        let coordinator = RecordingCoordinator(store: store)

        coordinator.markWaitingForUpload(recording.id)
        coordinator.markUploadStarted(
            recording.id,
            objectKey: "audio/example.m4a",
            sizeBytes: 2,
            mimeType: "audio/mp4",
            taskIdentifier: 17
        )
        coordinator.updateUploadProgress(recording.id, progress: 0.55)
        coordinator.markUploadFinalizing(recording.id)

        let persisted = try XCTUnwrap(store.loadRecordings().first)
        XCTAssertEqual(persisted.state, .finalizingUpload)
        XCTAssertEqual(persisted.uploadObjectKey, "audio/example.m4a")
        XCTAssertEqual(persisted.uploadSizeBytes, 2)
        XCTAssertEqual(persisted.uploadMimeType, "audio/mp4")
        XCTAssertEqual(persisted.uploadProgress, 1)
        XCTAssertNil(persisted.uploadTaskIdentifier)
    }

    func testImportedRecordingIsCopiedIntoDurableStorage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceDirectory)
        }
        let source = sourceDirectory.appendingPathComponent("meeting.mp4")
        let bytes = Data([0x10, 0x20, 0x30])
        try bytes.write(to: source)

        let store = try RecordingStore(rootDirectory: root)
        let imported = try store.importRecording(from: source, contentType: "meeting")

        XCTAssertEqual(imported.state, .ready)
        XCTAssertEqual(imported.contentType, "meeting")
        XCTAssertEqual(imported.originalFilename, "meeting.mp4")
        XCTAssertEqual(imported.displayTitle, "meeting")
        XCTAssertEqual(imported.uploadFilename, "meeting.mp4")
        XCTAssertEqual(imported.filename.split(separator: ".").last, "mp4")
        XCTAssertEqual(try Data(contentsOf: store.fileURL(for: imported)), bytes)
    }

    func testBackgroundUploadMetadataSurvivesTaskDescriptionRoundTrip() throws {
        let metadata = BackgroundUploadMetadata(
            recordingID: UUID(),
            ownerID: "user_uploading",
            filename: "memo.m4a",
            objectKey: "audio/random.m4a",
            sizeBytes: 42,
            mimeType: "audio/mp4",
            contentType: "voice_memo"
        )
        let restored = try JSONDecoder().decode(
            BackgroundUploadMetadata.self,
            from: JSONEncoder().encode(metadata)
        )
        XCTAssertEqual(restored, metadata)
        XCTAssertEqual(restored.ownerID, "user_uploading")

        let legacyData = try JSONSerialization.data(withJSONObject: [
            "recordingID": UUID().uuidString,
            "filename": "legacy.m4a",
            "objectKey": "audio/legacy.m4a",
            "sizeBytes": 42,
            "mimeType": "audio/mp4",
            "contentType": "voice_memo",
        ])
        XCTAssertNil(try JSONDecoder().decode(
            BackgroundUploadMetadata.self,
            from: legacyData
        ).ownerID)
    }

    func testTranscriptionWatchStorePersistsAndRemovesCompletedItems() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TranscriptionWatchStore(rootDirectory: directory)
        let recordingID = UUID()
        let watch = TranscriptionWatch(
            id: "audio-1",
            title: "Team sync",
            createdAt: Date(),
            recordingID: recordingID,
            authenticationPausedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        try store.save([watch])
        let restored = try XCTUnwrap(store.load().first)
        XCTAssertEqual(restored.id, watch.id)
        XCTAssertEqual(restored.title, watch.title)
        XCTAssertEqual(restored.createdAt.timeIntervalSince(watch.createdAt), 0, accuracy: 1)
        XCTAssertEqual(restored.recordingID, recordingID)
        XCTAssertEqual(restored.authenticationPausedAt, watch.authenticationPausedAt)
        try store.save([])
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testTranscriptionWatchDecodesManifestWrittenBeforeRecordingLink() throws {
        let data = Data(
            #"{"id":"audio-1","title":"Old watch","createdAt":"2026-08-21T03:00:00Z"}"#.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let watch = try decoder.decode(TranscriptionWatch.self, from: data)

        XCTAssertNil(watch.recordingID)
        XCTAssertNil(watch.authenticationPausedAt)
    }

    @MainActor
    func testDeviceCopyIsRetainedUntilServerProcessingCompletes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try RecordingStore(rootDirectory: directory)
        var recording = store.makeRecording(contentType: "voice_memo")
        recording.state = .ready
        let audioURL = store.fileURL(for: recording)
        try finalizedM4AData().write(to: audioURL)
        try store.saveRecordings([recording])
        let coordinator = RecordingCoordinator(store: store)

        coordinator.markServerAccepted(recording.id, transcriptionID: "audio-1")

        let processing = try XCTUnwrap(coordinator.recording(withID: recording.id))
        XCTAssertEqual(processing.state, .serverProcessing)
        XCTAssertEqual(processing.remoteTranscriptionID, "audio-1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))

        coordinator.markServerCompleted(recording.id)

        XCTAssertNil(coordinator.recording(withID: recording.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    }

    @MainActor
    func testPermanentServerSourceFailurePreservesDeviceCopyAsInvalid() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try RecordingStore(rootDirectory: directory)
        var recording = store.makeRecording(contentType: "voice_memo")
        recording.state = .ready
        let audioURL = store.fileURL(for: recording)
        try finalizedM4AData().write(to: audioURL)
        try store.saveRecordings([recording])
        let coordinator = RecordingCoordinator(store: store)

        coordinator.markServerAccepted(recording.id, transcriptionID: "audio-1")
        coordinator.markServerFailed(
            recording.id,
            message: "The source is invalid.",
            invalidSource: true
        )

        XCTAssertEqual(coordinator.recording(withID: recording.id)?.state, .invalid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
    }

    @MainActor
    func testSystemQuickCaptureRequiresAndManagesLiveActivity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let activityManager = TestRecordingActivityManager()
        let coordinator = RecordingCoordinator(
            store: try RecordingStore(rootDirectory: directory),
            simulatesCapture: true,
            activityManager: activityManager
        )

        let startOutcome = await coordinator.toggleFromSystem()
        XCTAssertEqual(startOutcome, .started)
        XCTAssertTrue(coordinator.isRecording)
        XCTAssertEqual(activityManager.startedRecording?.contentType, "voice_memo")

        XCTAssertTrue(coordinator.pause())
        XCTAssertTrue(coordinator.isPaused)
        let stopOutcome = await coordinator.toggleFromSystem()
        XCTAssertEqual(stopOutcome, .stopped)
        XCTAssertFalse(coordinator.isRecording)
        XCTAssertEqual(activityManager.endCount, 1)
        XCTAssertEqual(coordinator.availableRecordings.first?.state, .ready)
    }

    func testQuickRecordForegroundsBeforeStartingMicrophoneCapture() {
        XCTAssertTrue(QuickRecordIntent.openAppWhenRun)
    }

    func testShippingClientConfigurationIncludesClerk() {
        XCTAssertTrue(Configuration.clerkPublishableKey.hasPrefix("pk_"))
        XCTAssertFalse(Configuration.clerkPublishableKey.isEmpty)
    }

    @MainActor
    func testSystemQuickCaptureDoesNotRecordWithoutLiveActivities() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let activityManager = TestRecordingActivityManager()
        activityManager.areActivitiesEnabled = false
        let coordinator = RecordingCoordinator(
            store: try RecordingStore(rootDirectory: directory),
            simulatesCapture: true,
            activityManager: activityManager
        )

        let outcome = await coordinator.toggleFromSystem()
        XCTAssertEqual(outcome, .liveActivitiesDisabled)
        XCTAssertFalse(coordinator.isRecording)
        XCTAssertTrue(coordinator.pendingRecordings.isEmpty)
    }

    @MainActor
    func testSystemCaptureStopsIfLiveActivitiesBecomeUnavailableDuringStart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let activityManager = TestRecordingActivityManager()
        activityManager.activityAvailabilityChecks = [true, false]
        let coordinator = RecordingCoordinator(
            store: try RecordingStore(rootDirectory: directory),
            simulatesCapture: true,
            activityManager: activityManager
        )

        let outcome = await coordinator.toggleFromSystem()

        XCTAssertEqual(outcome, .liveActivitiesDisabled)
        XCTAssertFalse(coordinator.isRecording)
        let savedRecording = try XCTUnwrap(coordinator.availableRecordings.first)
        XCTAssertEqual(savedRecording.state, .ready)
        XCTAssertEqual(activityManager.endedRecordingIDs, [savedRecording.id])
    }

    @MainActor
    func testDelayedLiveActivityStartCannotOutliveStoppedRecording() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let activityManager = TestRecordingActivityManager()
        activityManager.pausesStart = true
        let coordinator = RecordingCoordinator(
            store: try RecordingStore(rootDirectory: directory),
            simulatesCapture: true,
            activityManager: activityManager
        )

        let startTask = Task { await coordinator.toggleFromSystem() }
        for _ in 0..<100 where !activityManager.isStartSuspended {
            await Task.yield()
        }
        XCTAssertTrue(activityManager.isStartSuspended)
        let recordingID = try XCTUnwrap(activityManager.startedRecording?.id)

        let stopOutcome = await coordinator.stopFromSystem()
        XCTAssertEqual(stopOutcome, .stopped)
        activityManager.resumeStart()
        let delayedStartOutcome = await startTask.value
        XCTAssertEqual(delayedStartOutcome, .stopped)

        XCTAssertFalse(coordinator.isRecording)
        XCTAssertEqual(coordinator.availableRecordings.first?.state, .ready)
        XCTAssertEqual(activityManager.endedRecordingIDs, [recordingID, recordingID])
    }

    @MainActor
    func testDelayedLiveActivityStartReconcilesAUserPause() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let activityManager = TestRecordingActivityManager()
        activityManager.pausesStart = true
        let coordinator = RecordingCoordinator(
            store: try RecordingStore(rootDirectory: directory),
            simulatesCapture: true,
            activityManager: activityManager
        )

        let startTask = Task { await coordinator.toggleFromSystem() }
        for _ in 0..<100 where !activityManager.isStartSuspended {
            await Task.yield()
        }
        XCTAssertTrue(activityManager.isStartSuspended)

        XCTAssertTrue(coordinator.pause())
        activityManager.resumeStart()
        let startOutcome = await startTask.value
        XCTAssertEqual(startOutcome, .started)
        XCTAssertTrue(coordinator.isPaused)
        XCTAssertEqual(activityManager.updates.last?.isPaused, true)

        let stopOutcome = await coordinator.stopFromSystem()
        XCTAssertEqual(stopOutcome, .stopped)
    }

    func testAudioProcessingStateDecodesIntoUsefulProgressCopy() throws {
        let data = Data(
            #"{"id":"audio-1","status":"processing","processing_stage":"splitting","processing_progress":35}"#
                .utf8)
        let item = try APIClient.makeDecoder().decode(AudioTranscription.self, from: data)

        XCTAssertEqual(item.processingStage, "splitting")
        XCTAssertEqual(item.processingProgress, 35)
        XCTAssertEqual(item.processingDescription, "Splitting long recording")
    }

    func testAudioReadableTranscriptUsesFormattedTextOnlyAfterCompletion() throws {
        let completed = try APIClient.makeDecoder().decode(
            AudioTranscription.self,
            from: Data(
                #"{"id":"audio-1","status":"completed","transcript_text":"testing this","formatted_transcript_text":"Testing this.","formatting_status":"completed"}"#.utf8
            )
        )
        XCTAssertEqual(completed.readableTranscriptText, "Testing this.")

        let pending = try APIClient.makeDecoder().decode(
            AudioTranscription.self,
            from: Data(
                #"{"id":"audio-2","status":"completed","transcript_text":"testing this","formatted_transcript_text":"","formatting_status":"pending"}"#.utf8
            )
        )
        XCTAssertEqual(pending.readableTranscriptText, "testing this")
    }

    func testAudioReadableTranscriptOnlyOffersOriginalWhenDisplayTextDiffers() throws {
        let unchanged = try APIClient.makeDecoder().decode(
            AudioTranscription.self,
            from: Data(
                #"{"id":"audio-1","status":"completed","transcript_text":"Testing this.","formatted_transcript_text":"Testing this.","formatting_status":"completed"}"#.utf8
            )
        )
        XCTAssertFalse(unchanged.hasDistinctReadableTranscript)

        let paragraphFormatting = try APIClient.makeDecoder().decode(
            AudioTranscription.self,
            from: Data(
                #"{"id":"audio-2","status":"completed","transcript_text":"Testing this. Testing that.","formatted_transcript_text":"Testing this.\n\nTesting that.","formatting_status":"completed"}"#.utf8
            )
        )
        XCTAssertTrue(paragraphFormatting.hasDistinctReadableTranscript)

        let pending = try APIClient.makeDecoder().decode(
            AudioTranscription.self,
            from: Data(
                #"{"id":"audio-3","status":"completed","transcript_text":"testing this","formatted_transcript_text":"Testing this.","formatting_status":"pending"}"#.utf8
            )
        )
        XCTAssertFalse(pending.hasDistinctReadableTranscript)
    }

    @MainActor
    func testLibrarySnapshotSurvivesReentryAndPrefetchesBeforeTheLastRow() async {
        let previewItems = (1...45).map { index in
            LibraryListItem(
                id: "audio-\(index)", itemType: "audio", title: "Recording \(index).m4a",
                subtitle: "EN", status: "completed", wordCount: index,
                duration: Double(index), pageCount: 0, summaryStatus: "", favorite: false,
                archived: false, tags: [], createdAt: Date().addingTimeInterval(Double(-index))
            )
        }
        let model = LibraryViewModel(previewItems: previewItems)

        await model.loadIfNeeded(for: model.query)
        XCTAssertEqual(model.items.count, 20)
        XCTAssertFalse(
            LibraryViewModel.shouldPrefetch(itemIndex: 14, itemCount: model.items.count)
        )
        XCTAssertTrue(
            LibraryViewModel.shouldPrefetch(itemIndex: 15, itemCount: model.items.count)
        )

        let anchor = model.items[10].reference
        model.visibleReference = anchor
        await model.prefetchIfNeeded(after: model.items[15].reference)
        XCTAssertEqual(model.items.count, 40)

        await model.loadIfNeeded(for: model.query)
        XCTAssertEqual(model.items.count, 40)
        XCTAssertEqual(model.visibleReference, anchor)
    }

    func testLibraryRowsUseHumanReadableTitlesAndMetadata() {
        let item = LibraryListItem(
            id: "audio-1", itemType: "audio", title: "Team planning.m4a", subtitle: "EN",
            status: "completed", wordCount: 100, duration: 72, pageCount: 0,
            summaryStatus: "", favorite: false, archived: false, tags: [],
            createdAt: Date(timeIntervalSince1970: 2_000_000_000)
        )

        XCTAssertEqual(item.displayTitle, "Team planning")
        XCTAssertNil(item.displaySubtitle)
        XCTAssertNotNil(item.createdDateText)

        let meaningfulSubtitle = LibraryListItem(
            id: "audio-2", itemType: "audio", title: "Song.m4a", subtitle: "Music",
            status: "completed", wordCount: 100, duration: 72, pageCount: 0,
            summaryStatus: "", favorite: false, archived: false, tags: [], createdAt: nil
        )
        XCTAssertEqual(meaningfulSubtitle.displaySubtitle, "Music")
    }

    @MainActor
    func testAudioPlayerUsesKnownDurationBeforeRemoteMetadataLoads() {
        let player = AudioPlayerService()
        player.load(
            url: URL(fileURLWithPath: "/tmp/media-tools-missing-audio.m4a"),
            knownDuration: 72
        )

        XCTAssertEqual(player.duration, 72)
        XCTAssertEqual(player.formattedDuration, "1:12")
        player.stop()
    }

    func testAudioUploadCompletionEncodesSemanticContentType() throws {
        let request = AudioUploadCompleteRequest(
            objectKey: "audio/user/upload.m4a",
            originalName: "Team sync.m4a",
            sizeBytes: 42,
            contentType: "meeting"
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any]
        )

        XCTAssertEqual(object["object_key"] as? String, "audio/user/upload.m4a")
        XCTAssertEqual(object["content_type"] as? String, "meeting")
        XCTAssertEqual(object["size_bytes"] as? Int, 42)
    }

    func testMultipartAudioBodyStreamsFileAndSanitizesFilename() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source.m4a")
        let destination = directory.appendingPathComponent("body.upload")
        let sourceBytes = Data([0x00, 0x01, 0x7F, 0xFF])
        try sourceBytes.write(to: source)

        try APIClient.writeMultipartBody(
            to: destination,
            sourceURL: source,
            filename: "memo\"\r\n.m4a",
            mimeType: "audio/mp4",
            fields: ["content_type": "voice_memo"],
            boundary: "test-boundary"
        )

        let body = try Data(contentsOf: destination)
        let header = try XCTUnwrap(String(data: body, encoding: .isoLatin1))
        XCTAssertTrue(header.contains("name=\"content_type\"\r\n\r\nvoice_memo"))
        XCTAssertTrue(header.contains("filename=\"memo.m4a\""))
        XCTAssertFalse(header.contains("memo\""))
        XCTAssertNotNil(body.range(of: sourceBytes))
        XCTAssertTrue(header.hasSuffix("\r\n--test-boundary--\r\n"))
    }

    func testAPIErrorsOnlyRetryTransientFailures() {
        XCTAssertTrue(APIError.invalidResponse.isRetryable)
        XCTAssertTrue(APIError.httpError(statusCode: 429, message: "Busy").isRetryable)
        XCTAssertTrue(APIError.httpError(statusCode: 503, message: "Unavailable").isRetryable)
        XCTAssertTrue(
            APIError.authenticationTemporarilyUnavailable(message: "Clerk unavailable").isRetryable
        )
        XCTAssertFalse(APIError.authenticationRequired(message: "Restoring sign-in").isRetryable)
        XCTAssertFalse(APIError.httpError(statusCode: 400, message: "Invalid").isRetryable)
        XCTAssertFalse(APIError.invalidFile(message: "Empty").isRetryable)
    }

    func testMultipartFallbackOnlyHandlesUnavailablePresigning() {
        XCTAssertTrue(
            APIError.httpError(statusCode: 503, code: "storage_unavailable", message: "No storage")
                .permitsMultipartUploadFallback
        )
        XCTAssertTrue(
            APIError.httpError(statusCode: 404, message: "Unknown endpoint")
                .permitsMultipartUploadFallback
        )
        XCTAssertFalse(
            APIError.httpError(statusCode: 401, code: "unauthorized", message: "Sign in")
                .permitsMultipartUploadFallback
        )
        XCTAssertFalse(
            APIError.httpError(statusCode: 429, code: "rate_limited", message: "Slow down")
                .permitsMultipartUploadFallback
        )
    }

    func testUnifiedLibraryResponseDecodesTypedMetadataAndPagination() throws {
        let data = Data(
            #"{"data":[{"id":"shared-id","item_type":"audio","title":"Team sync","subtitle":"EN","status":"processing","word_count":0,"duration":42.5,"page_count":0,"summary_status":"","favorite":true,"archived":false,"tags":["meeting"],"created_at":"2026-08-18T01:02:03Z"}],"page":2,"per_page":20,"total_items":41,"total_pages":3}"#
                .utf8)

        let response = try APIClient.makeDecoder().decode(LibraryListResponse.self, from: data)

        XCTAssertEqual(response.page, 2)
        XCTAssertEqual(response.totalItems, 41)
        XCTAssertEqual(response.totalPages, 3)
        XCTAssertEqual(response.data.first?.reference.id, "audio:shared-id")
        XCTAssertEqual(response.data.first?.tags, ["meeting"])
        XCTAssertEqual(response.data.first?.favorite, true)
    }

    func testLibraryReferencesIncludeTypeInIdentity() {
        let transcript = LibraryReference(itemType: "youtube", itemId: "shared-id")
        let audio = LibraryReference(itemType: "audio", itemId: "shared-id")

        XCTAssertNotEqual(transcript, audio)
        XCTAssertEqual(Set([transcript, audio]).count, 2)
        XCTAssertEqual(transcript.collectionItemType, "transcript")
        XCTAssertEqual(audio.collectionItemType, "audio")
    }

    func testSpotlightIdentifiersMatchLegacyAndUnifiedMediaPrefixes() {
        XCTAssertEqual(
            SpotlightService.libraryIdentifier(
                for: LibraryReference(itemType: "youtube", itemId: "video-id")
            ),
            "transcript-video-id"
        )
        XCTAssertEqual(
            SpotlightService.libraryIdentifier(
                for: LibraryReference(itemType: "audio", itemId: "audio-id")
            ),
            "audio-audio-id"
        )
        XCTAssertEqual(
            SpotlightService.libraryIdentifier(
                for: LibraryReference(itemType: "pdf", itemId: "pdf-id")
            ),
            "pdf-pdf-id"
        )
    }

    func testDetailNavigationDoesNotEquateDifferentMediaTypesWithTheSameID() throws {
        let transcript = try APIClient.makeDecoder().decode(
            Transcript.self,
            from: Data(#"{"id":"shared-id","status":"completed"}"#.utf8)
        )
        let audio = try APIClient.makeDecoder().decode(
            AudioTranscription.self,
            from: Data(#"{"id":"shared-id","status":"completed"}"#.utf8)
        )

        XCTAssertNotEqual(LibraryItem.transcript(transcript), LibraryItem.audio(audio))
    }

    func testLibraryPathEncodesCrossMediaSearchAndFilters() throws {
        let path = MediaToolsService.libraryItemsPath(
            page: 2,
            perPage: 30,
            itemType: "audio",
            status: "active",
            search: " payroll & tax ",
            sortDirection: "asc"
        )
        let components = try XCTUnwrap(URLComponents(string: path))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap {
            item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })

        XCTAssertEqual(components.path, "/library/items")
        XCTAssertEqual(query["page"], "2")
        XCTAssertEqual(query["per_page"], "30")
        XCTAssertEqual(query["type"], "audio")
        XCTAssertEqual(query["status"], "active")
        XCTAssertEqual(query["search"], "payroll & tax")
        XCTAssertEqual(query["sort_dir"], "asc")
    }
}

@MainActor
private final class TestRecordingActivityManager: RecordingActivityManaging {
    private var activitiesEnabled = true
    var activityAvailabilityChecks: [Bool] = []
    var areActivitiesEnabled: Bool {
        get {
            guard !activityAvailabilityChecks.isEmpty else { return activitiesEnabled }
            return activityAvailabilityChecks.removeFirst()
        }
        set {
            activitiesEnabled = newValue
            activityAvailabilityChecks = []
        }
    }
    var pausesStart = false
    private(set) var startedRecording: LocalRecording?
    private(set) var updates: [(
        isPaused: Bool,
        isInterrupted: Bool,
        duration: TimeInterval
    )] = []
    private(set) var endCount = 0
    private(set) var endedRecordingIDs: [UUID?] = []
    private(set) var isStartSuspended = false
    private var startContinuation: CheckedContinuation<Void, Never>?

    func start(for recording: LocalRecording) async throws {
        startedRecording = recording
        guard pausesStart else { return }
        isStartSuspended = true
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
        isStartSuspended = false
    }

    func resumeStart() {
        pausesStart = false
        startContinuation?.resume()
        startContinuation = nil
    }

    func update(
        recordingID: UUID,
        isPaused: Bool,
        isInterrupted: Bool,
        duration: TimeInterval
    ) async {
        updates.append((isPaused, isInterrupted, duration))
    }

    func end(recordingID: UUID?, finalDuration: TimeInterval) async {
        endCount += 1
        endedRecordingIDs.append(recordingID)
    }
}

@MainActor
private final class SuspendedRecordingUploadService: RecordingUploadServicing {
    private(set) var completeStarted = false
    private(set) var completionOwnerIDs: [String?] = []
    private var completionContinuation: CheckedContinuation<AudioTranscription, Error>?

    func getAudioItem(
        _ id: String,
        expectedOwnerID: String?
    ) async throws -> AudioTranscription {
        throw APIError.invalidResponse
    }

    func uploadAudio(
        fileURL: URL,
        filename: String,
        mimeType: String,
        contentType: String,
        expectedOwnerID: String?
    ) async throws -> AudioTranscription {
        throw APIError.invalidResponse
    }

    func presignAudioUpload(
        filename: String,
        mimeType: String,
        sizeBytes: Int64,
        expectedOwnerID: String?
    ) async throws -> AudioUploadPresignResponse {
        throw APIError.invalidResponse
    }

    func completeAudioUpload(
        _ completion: AudioUploadCompleteRequest,
        expectedOwnerID: String?
    ) async throws -> AudioTranscription {
        completeStarted = true
        completionOwnerIDs.append(expectedOwnerID)
        return try await withCheckedThrowingContinuation { continuation in
            completionContinuation = continuation
        }
    }

    func resumeCompletion(_ item: AudioTranscription) {
        completionContinuation?.resume(returning: item)
        completionContinuation = nil
    }
}
