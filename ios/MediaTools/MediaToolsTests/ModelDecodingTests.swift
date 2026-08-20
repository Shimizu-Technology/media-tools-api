import XCTest
@testable import MediaTools

final class ModelDecodingTests: XCTestCase {
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
    func testRecordingCoordinatorRecoversAndPreservesInterruptedCapture() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try RecordingStore(rootDirectory: directory)
        var recording = store.makeRecording(
            contentType: "meeting",
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        recording.duration = 37
        try Data([0x00, 0x01, 0x02]).write(to: store.fileURL(for: recording))
        try store.saveRecordings([recording])

        let coordinator = RecordingCoordinator(store: store)
        let recovered = try XCTUnwrap(coordinator.pendingRecordings.first)

        XCTAssertEqual(recovered.id, recording.id)
        XCTAssertEqual(recovered.contentType, "meeting")
        XCTAssertEqual(recovered.duration, 37)
        XCTAssertEqual(recovered.state, .interrupted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: recording).path))

        let reloaded = try XCTUnwrap(store.loadRecordings().first)
        XCTAssertEqual(reloaded.state, .interrupted)
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
    }

    func testTranscriptionWatchStorePersistsAndRemovesCompletedItems() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TranscriptionWatchStore(rootDirectory: directory)
        let watch = TranscriptionWatch(
            id: "audio-1",
            title: "Team sync",
            createdAt: Date(),
            authenticationPausedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        try store.save([watch])
        let restored = try XCTUnwrap(store.load().first)
        XCTAssertEqual(restored.id, watch.id)
        XCTAssertEqual(restored.title, watch.title)
        XCTAssertEqual(restored.createdAt.timeIntervalSince(watch.createdAt), 0, accuracy: 1)
        XCTAssertEqual(restored.authenticationPausedAt, watch.authenticationPausedAt)
        try store.save([])
        XCTAssertTrue(try store.load().isEmpty)
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

    func testAudioProcessingStateDecodesIntoUsefulProgressCopy() throws {
        let data = Data(
            #"{"id":"audio-1","status":"processing","processing_stage":"splitting","processing_progress":35}"#
                .utf8)
        let item = try APIClient.makeDecoder().decode(AudioTranscription.self, from: data)

        XCTAssertEqual(item.processingStage, "splitting")
        XCTAssertEqual(item.processingProgress, 35)
        XCTAssertEqual(item.processingDescription, "Splitting long recording")
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
    private(set) var updates: [(isInterrupted: Bool, duration: TimeInterval)] = []
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

    func update(recordingID: UUID, isInterrupted: Bool, duration: TimeInterval) async {
        updates.append((isInterrupted, duration))
    }

    func end(recordingID: UUID?, finalDuration: TimeInterval) async {
        endCount += 1
        endedRecordingIDs.append(recordingID)
    }
}
