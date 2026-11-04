import XCTest
@testable import MediaTools

private final class MemoryCredentials: ShareUploadCredentialStoring, @unchecked Sendable {
    var result: ShareUploadCredentialLoadResult = .missing
    var failsSaves = false
    private(set) var deletes = 0
    func load() -> ShareUploadCredentialLoadResult { result }
    func save(_ credential: ShareUploadCredential) throws {
        if failsSaves { throw CocoaError(.fileWriteUnknown) }
        result = .found(credential)
    }
    func delete() {
        deletes += 1
        result = .missing
    }
}

private final class ScriptedHTTP: ShareUploadHTTP, @unchecked Sendable {
    var status = 200
    var failure: Error?
    var requests: [URLRequest] = []
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if let failure { throw failure }
        let body = Data(#"{"upload_url":"https://bucket.test/put?sig=1","object_key":"audio/key-1.caf","stored_name":"key-1.caf","upload_id":"u","expires_in":"15m"}"#.utf8)
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private final class RecordingStarter: ShareBackgroundUploadStarting, @unchecked Sendable {
    var failure: Error?
    private(set) var calls: [(fileURL: URL, uploadURL: URL, metadata: BackgroundUploadMetadata, identifier: String)] = []
    func start(fileURL: URL, uploadURL: URL, metadata: BackgroundUploadMetadata, sessionIdentifier: String) throws {
        if let failure { throw failure }
        calls.append((fileURL, uploadURL, metadata, sessionIdentifier))
    }
}

/// The extension's half: when it may send a share, and that every other outcome
/// leaves the share saved for the app.
final class ShareDirectUploaderTests: XCTestCase {
    private var directory: URL!
    private var inbox: ShareInboxStore!
    private var policy: ShareUploadPolicyFileStore!
    private var credentials: MemoryCredentials!
    private var http: ScriptedHTTP!
    private var starter: RecordingStarter!
    private var uploader: ShareDirectUploader!
    private var source: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        inbox = try ShareInboxStore(rootURL: directory.appendingPathComponent("inbox"))
        policy = try ShareUploadPolicyFileStore(directoryURL: directory)
        credentials = MemoryCredentials()
        http = ScriptedHTTP()
        starter = RecordingStarter()
        uploader = ShareDirectUploader(
            inbox: inbox, credentials: credentials, policy: policy, http: http, starter: starter
        )
        source = directory.appendingPathComponent("memo.m4a")
        try Data(repeating: 0x42, count: 2048).write(to: source)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func allow(owner: String = "owner-a", mayUpload: Bool = true) throws {
        try policy.save(ShareUploadPolicy(
            ownerID: owner, mayUploadAutomatically: mayUpload, apiBaseURL: "https://api.test"
        ))
        credentials.result = .found(ShareUploadCredential(keyID: "k1", rawKey: "raw-key", ownerID: owner))
    }

    private func stage(for owner: String?) throws -> ShareInboxStore.Item {
        try inbox.stageFile(from: source, originalName: "Voice Memo.m4a", reservingDirectUploadFor: owner)
    }

    func testEligibilityNeedsConsentKeyAndMatchingOwner() throws {
        XCTAssertNil(uploader.eligibleOwnerID(), "No policy published")

        try policy.save(ShareUploadPolicy(ownerID: "owner-a", mayUploadAutomatically: true, apiBaseURL: "https://api.test"))
        XCTAssertNil(uploader.eligibleOwnerID(), "No key")

        credentials.result = .unavailable
        XCTAssertNil(uploader.eligibleOwnerID(), "Locked keychain")

        credentials.result = .found(ShareUploadCredential(keyID: "k1", rawKey: "raw", ownerID: "owner-b"))
        XCTAssertNil(uploader.eligibleOwnerID(), "Key for another account")

        try allow(mayUpload: false)
        XCTAssertNil(uploader.eligibleOwnerID(), "Consent missing or auto-transcribe off")

        try allow()
        XCTAssertEqual(uploader.eligibleOwnerID(), "owner-a")
    }

    func testAnUnreadablePolicyFileMeansNoPermission() throws {
        try allow()
        try Data("not json".utf8).write(to: directory.appendingPathComponent("share-upload-policy.json"))
        XCTAssertNil(uploader.eligibleOwnerID())
    }

    func testPresignsWithTheCaptureKeyAndHandsTheFileToTheTransferDaemon() async throws {
        try allow()
        let item = try stage(for: "owner-a")

        let outcome = await uploader.start(item)

        XCTAssertEqual(outcome, .uploading)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.test/api/v1/audio/uploads/presign")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "raw-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "The session token never leaves the app")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["filename"] as? String, "Voice Memo.m4a")
        XCTAssertEqual(body["size_bytes"] as? Int, 2048)

        let call = try XCTUnwrap(starter.calls.first)
        XCTAssertEqual(call.fileURL, inbox.fileURL(for: item), "Streams from the shared container")
        XCTAssertEqual(call.identifier, ShareDirectUpload.sessionIdentifier(for: item.id))
        XCTAssertEqual(call.metadata.recordingID, item.id, "The share ID is what prevents a second upload")
        XCTAssertEqual(call.metadata.ownerID, "owner-a")
        XCTAssertEqual(call.metadata.objectKey, "audio/key-1.caf")

        let saved = try XCTUnwrap(inbox.pendingItems().first)
        XCTAssertEqual(saved.directUpload?.objectKey, "audio/key-1.caf")
        XCTAssertEqual(saved.directUpload?.sizeBytes, 2048)
        XCTAssertEqual(saved.directUpload?.isStarted, true)
        XCTAssertEqual(saved.ownerID, "owner-a")
    }

    /// A short file can finish before the extension exits. iOS then reports to the
    /// extension and never wakes the app, so the extension must finish the job.
    func testATransferThatFinishesWhileRunningIsSavedThenCompletedWithTheKey() async throws {
        try allow()
        let item = try stage(for: "owner-a")
        _ = await uploader.start(item)
        let metadata = try XCTUnwrap(starter.calls.first?.metadata)
        http.requests.removeAll()

        await uploader.finishTransfer(metadata, statusCode: 200)

        XCTAssertEqual(try inbox.pendingItems().first?.directUpload?.uploadFinished, true)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.test/api/v1/audio/uploads/complete")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "raw-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["object_key"] as? String, "audio/key-1.caf")
        XCTAssertEqual(body["original_name"] as? String, "Voice Memo.m4a")
        XCTAssertEqual(body["size_bytes"] as? Int, 2048)
        XCTAssertEqual(body["content_type"] as? String, "general")
    }

    func testAFinishedTransferIsNotCompletedOncePermissionIsGone() async throws {
        try allow()
        let item = try stage(for: "owner-a")
        _ = await uploader.start(item)
        let metadata = try XCTUnwrap(starter.calls.first?.metadata)
        http.requests.removeAll()
        policy.clear()

        await uploader.finishTransfer(metadata, statusCode: 200)

        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(try inbox.pendingItems().first?.directUpload?.uploadFinished, true, "The app decides, with no second upload")
    }

    func testARejectedTransferReleasesTheShareForTheAppToSend() async throws {
        try allow()
        let item = try stage(for: "owner-a")
        _ = await uploader.start(item)
        let metadata = try XCTUnwrap(starter.calls.first?.metadata)
        http.requests.removeAll()

        await uploader.finishTransfer(metadata, statusCode: 403)

        XCTAssertNil(try inbox.pendingItems().first?.directUpload)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.fileURL(for: item).path))
    }

    func testAKeyRevokedBeforeCompleteIsForgotten() async throws {
        try allow()
        let item = try stage(for: "owner-a")
        _ = await uploader.start(item)
        let metadata = try XCTUnwrap(starter.calls.first?.metadata)
        http.status = 401

        await uploader.finishTransfer(metadata, statusCode: 200)

        XCTAssertEqual(credentials.deletes, 1)
        XCTAssertEqual(try inbox.pendingItems().first?.directUpload?.uploadFinished, true, "The bytes still arrived")
    }

    func testARevokedKeyIsForgottenAndTheShareWaitsForTheApp() async throws {
        try allow()
        let item = try stage(for: "owner-a")
        http.status = 401

        let outcome = await uploader.start(item)

        XCTAssertEqual(outcome, .savedForApp)
        XCTAssertEqual(credentials.deletes, 1)
        XCTAssertTrue(starter.calls.isEmpty)
        let saved = try XCTUnwrap(inbox.pendingItems().first)
        XCTAssertNil(saved.directUpload, "Released, so the app imports it at once")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.fileURL(for: saved).path))
    }

    func testEveryOtherFailureKeepsTheKeyAndTheShare() async throws {
        try allow()
        for setup in [
            { self.http.status = 500 },
            { self.http.status = 402 },
            { self.http.status = 503 },
            { self.http.status = 200; self.http.failure = URLError(.timedOut) },
            { self.http.failure = nil; self.starter.failure = CocoaError(.fileReadUnknown) },
        ] {
            setup()
            let item = try stage(for: "owner-a")
            let outcome = await uploader.start(item)
            XCTAssertEqual(outcome, .savedForApp)
            XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.fileURL(for: item).path))
        }
        XCTAssertEqual(credentials.deletes, 0)
        XCTAssertTrue(starter.calls.isEmpty)
        XCTAssertEqual(try inbox.pendingItems().count, 5)
    }

    func testPermissionRevokedDuringTheShareStopsBeforeTheNetwork() async throws {
        try allow()
        let item = try stage(for: "owner-a")
        policy.clear()

        let outcome = await uploader.start(item)

        XCTAssertEqual(outcome, .savedForApp)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testPDFsAreNeverReservedOrSent() async throws {
        try allow()
        let pdf = directory.appendingPathComponent("doc.pdf")
        try Data(repeating: 0x25, count: 16).write(to: pdf)

        let item = try inbox.stageFile(from: pdf, originalName: "doc.pdf", reservingDirectUploadFor: "owner-a")

        XCTAssertNil(item.directUpload)
        XCTAssertNil(item.ownerID)
        let outcome = await uploader.start(item)
        XCTAssertEqual(outcome, .savedForApp)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testAReservationExpiresSoADeadExtensionCannotHoldAShare() throws {
        let start = Date()
        let reservation = ShareInboxStore.DirectUpload(reservedAt: start)
        XCTAssertTrue(reservation.isReservationActive(now: start.addingTimeInterval(10)))
        XCTAssertFalse(reservation.isReservationActive(now: start.addingTimeInterval(61)))
        var started = reservation
        started.sessionIdentifier = "s"
        started.objectKey = "k"
        started.sizeBytes = 1
        started.mimeType = "audio/mp4"
        XCTAssertFalse(started.isReservationActive(now: start), "A started upload holds nothing")
    }

    @MainActor
    func testMIMETypeIsStableBetweenPresignAndPut() {
        XCTAssertEqual(ShareDirectUpload.mimeType(for: URL(fileURLWithPath: "/a/source.caf")), "audio/x-caf")
        XCTAssertEqual(
            ShareDirectUpload.mimeType(for: URL(fileURLWithPath: "/a/source.m4a")),
            RecordingUploadCoordinator.mimeType(for: URL(fileURLWithPath: "/b/other.m4a"))
        )
    }

    func testSessionIdentifiersAreUniquePerShareAndRecognized() {
        let a = ShareDirectUpload.sessionIdentifier(for: UUID())
        let b = ShareDirectUpload.sessionIdentifier(for: UUID())
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(ShareDirectUpload.isShareSession(a))
        XCTAssertFalse(ShareDirectUpload.isShareSession(BackgroundUploadService.sessionIdentifier))
    }
}

private actor ScriptedKeyAPI: ShareUploadKeyAPI {
    var mintFailure: Error?
    var revokeFailure: Error?
    var listed: [ListedAPIKey] = []
    private(set) var minted: [String] = []
    private(set) var revokedWithSession: [String] = []
    private(set) var revokedWithBearer: [String] = []
    private var mintGate: CheckedContinuation<Void, Never>?
    private var holdsMint = false

    func set(mintFailure: Error? = nil, revokeFailure: Error? = nil) {
        self.mintFailure = mintFailure
        self.revokeFailure = revokeFailure
    }

    func set(listed: [ListedAPIKey]) { self.listed = listed }
    func holdNextMint() { holdsMint = true }

    func releaseMint() {
        mintGate?.resume()
        mintGate = nil
    }

    func waitForHeldMint() async {
        while mintGate == nil { await Task.yield() }
    }

    func createShareUploadKey(name: String, ownerID: String) async throws -> ShareUploadKeyResponse {
        if holdsMint {
            holdsMint = false
            await withCheckedContinuation { mintGate = $0 }
        }
        if let mintFailure { throw mintFailure }
        minted.append(name)
        return ShareUploadKeyResponse(id: "key-\(minted.count)", rawKey: "raw-\(minted.count)")
    }

    func listAPIKeys(ownerID: String) async throws -> [ListedAPIKey] { listed }

    func revokeAPIKey(id: String, ownerID: String) async throws {
        if let revokeFailure { throw revokeFailure }
        revokedWithSession.append(id)
    }

    func revokeAPIKey(id: String, bearerToken: String) async throws {
        if let revokeFailure { throw revokeFailure }
        revokedWithBearer.append(id)
    }
}

@MainActor
final class ShareUploadKeyManagerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var credentials: MemoryCredentials!
    private var api: ScriptedKeyAPI!
    private var manager: ShareUploadKeyManager!

    override func setUp() async throws {
        suiteName = "ShareUploadKeyManagerTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        credentials = MemoryCredentials()
        api = ScriptedKeyAPI()
        manager = ShareUploadKeyManager(credentials: credentials, api: api, defaults: defaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testRequestAsksForTheCaptureScopeAndNothingElse() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let object = try JSONSerialization.jsonObject(with: encoder.encode(
            CreateShareUploadKeyRequest(name: "n", scopes: ["capture:upload"])
        )) as? [String: Any]
        XCTAssertEqual(object?["scopes"] as? [String], ["capture:upload"])
        let response = try APIClient.makeDecoder().decode(ShareUploadKeyResponse.self, from: Data(#"""
        {"id":"k1","key_prefix":"mta_abc...","name":"n","active":true,"rate_limit":2000,
         "created_at":"2026-11-04T00:00:00Z","scopes":["capture:upload"],"raw_key":"secret"}
        """#.utf8))
        XCTAssertEqual(response.rawKey, "secret")
    }

    func testMintsOnceAndBindsTheKeyToItsOwner() async throws {
        await manager.ensureKey(ownerID: "owner-a")
        await manager.ensureKey(ownerID: "owner-a")

        let minted = await api.minted
        XCTAssertEqual(minted.count, 1)
        XCTAssertEqual(credentials.result, .found(ShareUploadCredential(keyID: "key-1", rawKey: "raw-1", ownerID: "owner-a")))
    }

    func testMintFailureIsQuietAndRetriedLater() async throws {
        await api.set(mintFailure: URLError(.notConnectedToInternet))
        await manager.ensureKey(ownerID: "owner-a")
        XCTAssertEqual(credentials.result, .missing)

        await api.set(mintFailure: nil)
        await manager.ensureKey(ownerID: "owner-a")
        guard case .found = credentials.result else {
            return XCTFail("The next foreground tries again")
        }
    }

    func testALockedKeychainMintsNothing() async throws {
        credentials.result = .unavailable
        await manager.ensureKey(ownerID: "owner-a")
        let minted = await api.minted
        XCTAssertTrue(minted.isEmpty, "A key that cannot be saved would be stranded on the account")
    }

    func testAKeyThatCannotBeSavedIsRevokedStraightAway() async throws {
        credentials.failsSaves = true
        await manager.ensureKey(ownerID: "owner-a")
        let revoked = await api.revokedWithSession
        XCTAssertEqual(revoked, ["key-1"])
    }

    func testSignOutStopsTheExtensionEvenOffline() async throws {
        await manager.ensureKey(ownerID: "owner-a")
        await api.set(revokeFailure: URLError(.notConnectedToInternet))

        manager.endCredential()

        XCTAssertEqual(credentials.result, .missing)

        // Offline at sign-out, so the same account's next session finishes it.
        await api.set(revokeFailure: nil)
        await manager.ensureKey(ownerID: "owner-a")
        let revoked = await api.revokedWithSession
        XCTAssertEqual(revoked, ["key-1"])
    }

    func testAnotherAccountNeverRevokesOrUsesThisKey() async throws {
        await manager.ensureKey(ownerID: "owner-a")
        manager.endCredential()

        await manager.ensureKey(ownerID: "owner-b")

        let revoked = await api.revokedWithSession
        XCTAssertTrue(revoked.isEmpty, "Only owner-a can revoke owner-a's key")
        XCTAssertEqual(credentials.result, .found(ShareUploadCredential(keyID: "key-2", rawKey: "raw-2", ownerID: "owner-b")))

        manager.endCredential()
        await manager.ensureKey(ownerID: "owner-a")
        let afterReturn = await api.revokedWithSession
        XCTAssertEqual(afterReturn, ["key-1"])
    }

    func testAStoredKeyForAnotherAccountIsReplaced() async throws {
        credentials.result = .found(ShareUploadCredential(keyID: "old", rawKey: "raw-old", ownerID: "owner-a"))
        await manager.ensureKey(ownerID: "owner-b")
        XCTAssertEqual(credentials.result, .found(ShareUploadCredential(keyID: "key-1", rawKey: "raw-1", ownerID: "owner-b")))
    }

    func testSigningOutDuringAMintNeverInstallsTheKey() async throws {
        await api.holdNextMint()
        let mint = Task { await manager.ensureKey(ownerID: "owner-a") }
        await api.waitForHeldMint()

        manager.endCredential()
        await api.releaseMint()
        await mint.value

        XCTAssertEqual(credentials.result, .missing)

        // The stranded key is revoked the next time this account has a session.
        await manager.ensureKey(ownerID: "owner-a")
        let revoked = await api.revokedWithSession
        XCTAssertEqual(revoked, ["key-1"])
    }

    func testAPasswordResetRevokedKeyIsJustReplaced() async throws {
        await manager.ensureKey(ownerID: "owner-a")
        // The extension saw a 401 and removed the credential.
        credentials.delete()

        await manager.ensureKey(ownerID: "owner-a")

        XCTAssertEqual(credentials.result, .found(ShareUploadCredential(keyID: "key-2", rawKey: "raw-2", ownerID: "owner-a")))
    }

    func testALostMintResponseIsCleanedUpByThisInstallsName() async throws {
        await manager.ensureKey(ownerID: "owner-a")
        guard case .found(let first) = credentials.result else { return XCTFail("Expected a key") }
        let name = await api.minted[0]
        credentials.delete()
        await api.set(listed: [
            ListedAPIKey(id: first.keyID, name: name, active: true, scopes: ["capture:upload"]),
            ListedAPIKey(id: "key-2", name: name, active: true, scopes: ["capture:upload"]),
            ListedAPIKey(id: "agent", name: "My agent", active: true, scopes: ["library:read"]),
            ListedAPIKey(id: "gone", name: name, active: false, scopes: ["capture:upload"]),
        ])

        await manager.ensureKey(ownerID: "owner-a")

        let revoked = await api.revokedWithSession
        XCTAssertEqual(revoked, [first.keyID], "The new key and every other key stay")
    }

    func testAccountDeletionForgetsTheKeyWithNothingLeftToRevoke() async throws {
        await manager.ensureKey(ownerID: "owner-a")
        manager.endCredential()
        await manager.ensureKey(ownerID: "owner-a")

        manager.accountDeleted(ownerID: "owner-a")

        XCTAssertEqual(credentials.result, .missing)
        let before = await api.revokedWithSession
        await manager.ensureKey(ownerID: "owner-a")
        let after = await api.revokedWithSession
        XCTAssertEqual(before, after)
    }

    func testSessionRevocationRevokesTheKeyWithThatSessionsToken() async throws {
        let store = UpdateSessionStore(StoredDeviceSession(
            pair: DeviceSessionPair(
                sessionID: "session-a", userID: "owner-a", accessToken: "access",
                accessExpiresAt: .distantFuture, refreshToken: "refresh", inactiveExpiresAt: .distantFuture
            ),
            source: .passkey
        ))
        let session = DeviceSessionController(
            transport: AcceptAllTransport(),
            baseURL: URL(string: "https://example.test/api/v1")!,
            store: store,
            retiredLegacyIdentities: UpdateRetiredIdentities()
        )
        manager.follow(session)
        await manager.ensureKey(ownerID: "owner-a")

        try await session.revokeOrSuspend()

        XCTAssertEqual(credentials.result, .missing)
        XCTAssertNil(store.value)
        let revoked = await api.revokedWithBearer
        XCTAssertEqual(revoked, ["key-1"])
    }

    func testARejectedSessionRemovesTheKeyFromThisIPhone() async throws {
        let store = UpdateSessionStore(StoredDeviceSession(
            pair: DeviceSessionPair(
                sessionID: "session-a", userID: "owner-a", accessToken: "access",
                accessExpiresAt: .distantPast, refreshToken: "refresh", inactiveExpiresAt: .distantFuture
            ),
            source: .passkey
        ))
        let session = DeviceSessionController(
            transport: RejectAllTransport(),
            baseURL: URL(string: "https://example.test/api/v1")!,
            store: store,
            retiredLegacyIdentities: UpdateRetiredIdentities()
        )
        manager.follow(session)
        credentials.result = .found(ShareUploadCredential(keyID: "k", rawKey: "raw", ownerID: "owner-a"))

        let owner = await session.activate()

        XCTAssertNil(owner)
        XCTAssertTrue(session.needsSignIn)
        XCTAssertEqual(credentials.result, .missing)
        XCTAssertNotNil(store.value, "The session itself is left for sign-in to replace")
    }
}

private struct AcceptAllTransport: DeviceSessionTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
    }
}

private struct RejectAllTransport: DeviceSessionTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
    }
}

/// The flags the extension reads must always match the app's own answer, and
/// lean toward no permission when they cannot.
@MainActor
final class SharePolicyPublishingTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var policy: ShareUploadPolicyFileStore!
    private var consent: AIProcessingConsentManager!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "SharePolicyPublishingTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        policy = try ShareUploadPolicyFileStore(directoryURL: directory)
        consent = AIProcessingConsentManager(
            defaults: defaults, sharePolicy: policy, apiBaseURL: "https://api.test"
        )
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    func testFlagsFollowConsentSettingAndAccount() {
        XCTAssertNil(policy.load())

        consent.setActiveOwnerID("owner-a")
        XCTAssertEqual(policy.load()?.ownerID, "owner-a")
        XCTAssertEqual(policy.load()?.mayUploadAutomatically, false)
        XCTAssertEqual(policy.load()?.apiBaseURL, "https://api.test")

        consent.allow()
        XCTAssertEqual(policy.load()?.mayUploadAutomatically, true)

        consent.setAutoTranscribeEnabled(false)
        XCTAssertEqual(policy.load()?.mayUploadAutomatically, false)

        consent.setAutoTranscribeEnabled(true)
        XCTAssertEqual(policy.load()?.mayUploadAutomatically, true)

        consent.revoke()
        XCTAssertEqual(policy.load()?.mayUploadAutomatically, false)

        consent.setActiveOwnerID(nil)
        XCTAssertNil(policy.load())
    }

    func testAnOlderGrantDoesNotAuthorizeAutomaticUploads() throws {
        // The v1 grant promised audio goes only on request.
        defaults.set(["owner-a"], forKey: "aiProcessingConsentedOwnerIDs.v1")
        consent.setActiveOwnerID("owner-a")
        XCTAssertTrue(consent.hasConsent)
        XCTAssertEqual(policy.load()?.mayUploadAutomatically, false)
    }

    func testAccountsDoNotShareAnAnswer() {
        consent.setActiveOwnerID("owner-a")
        consent.allow()
        consent.setActiveOwnerID("owner-b")
        XCTAssertEqual(policy.load()?.ownerID, "owner-b")
        XCTAssertEqual(policy.load()?.mayUploadAutomatically, false)
    }

    func testMigrationCarriesTheAnswerToTheServerID() {
        consent.setActiveOwnerID("user_legacy")
        consent.allow()
        consent.migrateConsent(from: "user_legacy", to: "server-a")
        consent.setActiveOwnerID("server-a")
        XCTAssertEqual(policy.load()?.ownerID, "server-a")
        XCTAssertEqual(policy.load()?.mayUploadAutomatically, true)
    }
}

@MainActor
private final class CountingUploadService: RecordingUploadServicing {
    private(set) var presigns: [String] = []
    private(set) var completions: [(request: AudioUploadCompleteRequest, owner: String?)] = []
    var completionError: Error?

    func getAudioItem(_ id: String, expectedOwnerID: String?) async throws -> AudioTranscription {
        throw URLError(.notConnectedToInternet)
    }
    func uploadAudio(fileURL: URL, filename: String, mimeType: String, contentType: String, expectedOwnerID: String?) async throws -> AudioTranscription {
        throw URLError(.notConnectedToInternet)
    }
    func presignAudioUpload(filename: String, mimeType: String, sizeBytes: Int64, expectedOwnerID: String?) async throws -> AudioUploadPresignResponse {
        presigns.append(filename)
        throw URLError(.notConnectedToInternet)
    }
    func completeAudioUpload(_ completion: AudioUploadCompleteRequest, expectedOwnerID: String?) async throws -> AudioTranscription {
        completions.append((completion, expectedOwnerID))
        if let completionError { throw completionError }
        let data = Data(#"{"id":"remote-1","title":"Memo","status":"pending"}"#.utf8)
        return try APIClient.makeDecoder().decode(AudioTranscription.self, from: data)
    }
    func importSharedLink(_ link: String, expectedOwnerID: String?) async throws {}
    func importSharedPDF(fileURL: URL, filename: String, expectedOwnerID: String?) async throws {}
}

@MainActor
private final class SilentActivities: RecordingActivityManaging {
    let areActivitiesEnabled = true
    func start(for recording: LocalRecording) async throws {}
    func update(recordingID: UUID, isPaused: Bool, isInterrupted: Bool, duration: TimeInterval) async {}
    func end(recordingID: UUID?, finalDuration: TimeInterval) async {}
}

/// The app's half: a share the extension is sending is imported rather than sent
/// again, finishes through the ordinary recording states, and stays with its owner.
@MainActor
final class ShareUploadImportTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var inbox: ShareInboxStore!
    private var consent: AIProcessingConsentManager!
    private var recorder: RecordingCoordinator!
    private var uploader: RecordingUploadCoordinator!
    private var service: CountingUploadService!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "ShareUploadImportTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        inbox = try ShareInboxStore(rootURL: directory.appendingPathComponent("inbox"))
        consent = AIProcessingConsentManager(defaults: defaults)
        recorder = RecordingCoordinator(
            store: try RecordingStore(rootDirectory: directory.appendingPathComponent("recordings")),
            simulatesCapture: true,
            activityManager: SilentActivities(),
            localAccountDefaults: defaults,
            availableCapacity: { _ in 10 * 1_024 * 1_024 * 1_024 },
            shareInbox: inbox
        )
        service = CountingUploadService()
        uploader = RecordingUploadCoordinator(
            recorder: recorder,
            service: service,
            watchStore: try TranscriptionWatchStore(rootDirectory: directory.appendingPathComponent("watches")),
            localAccountDefaults: defaults,
            aiProcessingConsent: consent,
            isForeground: { true }
        )
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    private func signIn(_ ownerID: String?, withConsent: Bool = true) async {
        consent.setActiveOwnerID(ownerID)
        if withConsent, ownerID != nil { consent.allow() }
        await uploader.setActiveOwnerID(ownerID)
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() {
            await Task.yield()
        }
    }

    /// A valid CAF, because import runs the same integrity check as any recording.
    private func simulatedCAF() throws -> URL {
        func chunk(_ type: String, payload: Data) -> Data {
            let size = UInt64(payload.count)
            var data = Data(type.utf8)
            data.append(contentsOf: (0..<8).reversed().map { UInt8((size >> UInt64($0 * 8)) & 0xff) })
            data.append(payload)
            return data
        }
        var description = Data(count: 32)
        description.replaceSubrange(8..<12, with: Data("lpcm".utf8))
        let url = directory.appendingPathComponent("\(UUID().uuidString).caf")
        try (Data("caff".utf8) + Data([0x00, 0x01, 0x00, 0x00])
            + chunk("desc", payload: description)
            + chunk("data", payload: Data([0, 0, 0, 0, 1, 0]))).write(to: url)
        return url
    }

    private func stage(owner: String?, started: Bool) throws -> ShareInboxStore.Item {
        var item = try inbox.stageFile(
            from: try simulatedCAF(),
            originalName: "Call v2.1",
            reservingDirectUploadFor: owner
        )
        if started {
            let identifier = ShareDirectUpload.sessionIdentifier(for: item.id)
            item.directUpload?.sessionIdentifier = identifier
            item.directUpload?.objectKey = "audio/share.caf"
            item.directUpload?.sizeBytes = 66
            item.directUpload?.mimeType = "audio/x-caf"
            try inbox.update(item)
        }
        return item
    }

    private func metadata(_ item: ShareInboxStore.Item, objectKey: String = "audio/share.caf") -> BackgroundUploadMetadata {
        BackgroundUploadMetadata(
            recordingID: item.id,
            ownerID: item.ownerID,
            filename: item.originalName,
            objectKey: objectKey,
            sizeBytes: 66,
            mimeType: "audio/x-caf",
            contentType: "general"
        )
    }

    func testAStartedShareImportsAsUploadingAndIsNotSentAgain() async throws {
        await signIn("owner-a")
        let item = try stage(owner: "owner-a", started: true)

        uploader.processSharedItems()

        let recording = try XCTUnwrap(recorder.recording(withID: item.id))
        XCTAssertEqual(recording.state, .uploading)
        XCTAssertEqual(recording.uploadObjectKey, "audio/share.caf")
        XCTAssertEqual(recording.ownerID, "owner-a")
        await settle { !service.presigns.isEmpty }
        XCTAssertTrue(service.presigns.isEmpty)
        XCTAssertEqual(try inbox.pendingItems().map(\.id), [item.id], "iOS may still be reading this file")
        XCTAssertTrue(recorder.sharesNeedingAttention.isEmpty, "It is on its way, not stuck")
    }

    func testFinishedUploadCompletesOnceWithTheOwnersSessionAndFreesTheInbox() async throws {
        await signIn("owner-a")
        let item = try stage(owner: "owner-a", started: true)

        // As on a background wake: the first thing this app hears is the result.
        uploader.receiveBackgroundUploadEvent(.completed(metadata: metadata(item)))
        await settle { !service.completions.isEmpty }

        XCTAssertEqual(service.completions.count, 1)
        XCTAssertEqual(service.completions.first?.request.objectKey, "audio/share.caf")
        XCTAssertEqual(service.completions.first?.request.originalName, "Call v2.1.caf", "Must match the presign")
        XCTAssertEqual(service.completions.first?.owner, "owner-a")
        await settle { recorder.recording(withID: item.id)?.state == .serverProcessing }
        XCTAssertEqual(recorder.recording(withID: item.id)?.state, .serverProcessing)
        XCTAssertTrue(service.presigns.isEmpty, "Never uploaded a second time")
        XCTAssertTrue(try inbox.pendingItems().isEmpty)
        let recording = try XCTUnwrap(recorder.recording(withID: item.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(recorder.fileURL(for: recording)).path), "The device copy stays until the transcript exists")
    }

    func testAFinishedUploadIsNeverSentAgainWhenTheAppOpensLater() async throws {
        await signIn("owner-a")
        var item = try stage(owner: "owner-a", started: true)
        item.directUpload?.uploadFinished = true
        try inbox.update(item)

        uploader.processSharedItems()
        uploader.resumePendingWork()

        await settle { !service.completions.isEmpty }
        XCTAssertEqual(service.completions.first?.request.objectKey, "audio/share.caf", "Replays the same object")
        XCTAssertTrue(service.presigns.isEmpty, "The bytes are already there")
        XCTAssertTrue(try inbox.pendingItems().isEmpty)
    }

    func testAnUploadThatFinishesAfterImportIsNotSentAgain() async throws {
        await signIn("owner-a")
        var item = try stage(owner: "owner-a", started: true)
        uploader.processSharedItems()
        XCTAssertEqual(recorder.recording(withID: item.id)?.state, .uploading)

        item.directUpload?.uploadFinished = true
        try inbox.update(item)
        recorder.importSharedItems()

        XCTAssertEqual(recorder.recording(withID: item.id)?.state, .finalizingUpload)
        XCTAssertEqual(recorder.recording(withID: item.id)?.uploadObjectKey, "audio/share.caf")
    }

    func testAReservedShareWaitsForTheExtension() async throws {
        await signIn("owner-a")
        let item = try stage(owner: "owner-a", started: false)

        uploader.processSharedItems()

        XCTAssertNil(recorder.recording(withID: item.id), "It may start uploading any moment")
        XCTAssertTrue(recorder.sharesNeedingAttention.isEmpty)
        XCTAssertTrue(recorder.hasShareReservations)
        XCTAssertEqual(try inbox.pendingItems().map(\.id), [item.id])
    }

    func testAnExpiredReservationImportsAndUploadsNormally() async throws {
        await signIn("owner-a")
        var item = try stage(owner: "owner-a", started: false)
        item.directUpload = ShareInboxStore.DirectUpload(reservedAt: Date().addingTimeInterval(-120))
        try inbox.update(item)

        uploader.processSharedItems()

        XCTAssertEqual(recorder.recording(withID: item.id)?.ownerID, "owner-a")
        await settle { !service.presigns.isEmpty }
        XCTAssertEqual(service.presigns, ["Call v2.1.caf"], "The ordinary path takes over, with no loss")
        XCTAssertTrue(try inbox.pendingItems().isEmpty)
    }

    func testAReleasedShareUploadsThroughTheOrdinaryPath() async throws {
        await signIn("owner-a")
        var item = try stage(owner: "owner-a", started: false)
        item.directUpload = nil
        try inbox.update(item)

        uploader.processSharedItems()

        await settle { !service.presigns.isEmpty }
        XCTAssertEqual(service.presigns, ["Call v2.1.caf"])
    }

    func testAShareFromAnotherAccountStaysWithThatAccount() async throws {
        await signIn("owner-b")
        let item = try stage(owner: "owner-a", started: true)

        uploader.processSharedItems()

        let recording = try XCTUnwrap(recorder.recording(withID: item.id))
        XCTAssertEqual(recording.ownerID, "owner-a")
        XCTAssertTrue(recorder.availableRecordings.isEmpty, "owner-b never sees it")

        uploader.receiveBackgroundUploadEvent(.completed(metadata: metadata(item)))
        await settle { !service.completions.isEmpty }
        XCTAssertTrue(service.completions.isEmpty, "owner-b's session must never finish it")
        XCTAssertEqual(recorder.recording(withID: item.id)?.state, .finalizingUpload)

        // When its owner returns it finishes with their session and no re-upload.
        await signIn("owner-a")
        await settle { !service.completions.isEmpty }
        XCTAssertEqual(service.completions.first?.owner, "owner-a")
        XCTAssertTrue(service.presigns.isEmpty)
    }

    func testSignOutDuringAnUploadKeepsTheRecordingAndFinishesAfterSignIn() async throws {
        await signIn("owner-a")
        let item = try stage(owner: "owner-a", started: true)
        uploader.processSharedItems()

        await signIn(nil)
        XCTAssertNotNil(recorder.recording(withID: item.id))

        uploader.receiveBackgroundUploadEvent(.completed(metadata: metadata(item)))
        await settle { !service.completions.isEmpty }
        XCTAssertTrue(service.completions.isEmpty, "There is no session to use")
        XCTAssertEqual(recorder.recording(withID: item.id)?.state, .finalizingUpload)
        let recording = try XCTUnwrap(recorder.recording(withID: item.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(recorder.fileURL(for: recording)).path))

        await signIn("owner-a", withConsent: false)
        await settle { !service.completions.isEmpty }
        XCTAssertEqual(service.completions.count, 1)
    }

    func testRejectedSessionDuringCompleteKeepsTheUploadForSignIn() async throws {
        await signIn("owner-a")
        service.completionError = APIError.authenticationRequired(message: "Sign in to continue.")
        let item = try stage(owner: "owner-a", started: true)

        uploader.receiveBackgroundUploadEvent(.completed(metadata: metadata(item)))
        await settle { recorder.recording(withID: item.id)?.lastError != nil }

        let recording = try XCTUnwrap(recorder.recording(withID: item.id))
        XCTAssertEqual(recording.state, .finalizingUpload)
        XCTAssertEqual(recording.uploadObjectKey, "audio/share.caf", "The finished upload is not thrown away")
    }

    func testAFailedTransferRetriesFromTheDeviceCopy() async throws {
        await signIn("owner-a")
        let item = try stage(owner: "owner-a", started: true)
        uploader.processSharedItems()

        uploader.receiveBackgroundUploadEvent(.failed(
            metadata: metadata(item), message: "Connection lost", shouldRetry: true
        ))

        XCTAssertEqual(recorder.recording(withID: item.id)?.state, .waitingForUpload)
        XCTAssertNil(recorder.recording(withID: item.id)?.shareUploadSessionIdentifier)
        XCTAssertTrue(try inbox.pendingItems().isEmpty, "The recording store has its own copy")
    }

    func testAStaleTaskCannotFinishARecordingThatMovedOn() async throws {
        await signIn("owner-a")
        let item = try stage(owner: "owner-a", started: true)
        uploader.processSharedItems()

        uploader.receiveBackgroundUploadEvent(.completed(
            metadata: metadata(item, objectKey: "audio/older-attempt.caf")
        ))
        await settle { !service.completions.isEmpty }

        XCTAssertTrue(service.completions.isEmpty, "A second object would mean a second transcription")
        XCTAssertEqual(recorder.recording(withID: item.id)?.state, .uploading)
    }

    func testTurningAutoTranscribeOffBeforeImportStopsTheUpload() async throws {
        await signIn("owner-a")
        consent.setAutoTranscribeEnabled(false)
        let item = try stage(owner: "owner-a", started: true)

        uploader.processSharedItems()

        let recording = try XCTUnwrap(recorder.recording(withID: item.id))
        XCTAssertEqual(recording.state, .ready)
        XCTAssertNil(recording.uploadObjectKey)

        uploader.receiveBackgroundUploadEvent(.completed(metadata: metadata(item)))
        await settle { !service.completions.isEmpty }
        XCTAssertTrue(service.completions.isEmpty)
    }

    func testRevokingConsentBeforeImportReturnsTheShareToSaved() async throws {
        await signIn("owner-a")
        consent.revoke()
        let item = try stage(owner: "owner-a", started: true)

        uploader.processSharedItems()
        uploader.resumePendingWork()

        XCTAssertEqual(recorder.recording(withID: item.id)?.state, .ready)
        uploader.receiveBackgroundUploadEvent(.completed(metadata: metadata(item)))
        await settle { !service.completions.isEmpty }
        XCTAssertTrue(service.completions.isEmpty)
    }

    func testAccountDeletionRemovesAShareThatWasMidUpload() async throws {
        await signIn("owner-a")
        let item = try stage(owner: "owner-a", started: true)

        await uploader.removeLocalAccountData(ownerID: "owner-a")

        XCTAssertNil(recorder.recording(withID: item.id))
        XCTAssertTrue(try inbox.pendingItems().isEmpty)
    }

    func testLegacyProviderOwnersAreFoundOnlyWhenPresent() async throws {
        XCTAssertTrue(recorder.legacyProviderOwnerIDs.isEmpty)
        recorder.setActiveOwnerID("user_2abc")
        recorder.start(contentType: "voice_memo")
        recorder.stop()
        recorder.setActiveOwnerID("c0a80101-0000-4000-8000-000000000001")
        XCTAssertEqual(recorder.legacyProviderOwnerIDs, ["user_2abc"])
    }

    func testOldManifestWithoutTheNewFieldStillLoads() throws {
        let json = #"""
        {"id":"9f1a7a43-4ce8-4d52-9b0a-2b7f8a2cbb11","filename":"a.caf","createdAt":0,"duration":1,
         "contentType":"general","state":"ready"}
        """#
        let recording = try JSONDecoder().decode(LocalRecording.self, from: Data(json.utf8))
        XCTAssertNil(recording.shareUploadSessionIdentifier)
    }
}
