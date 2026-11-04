import XCTest
@testable import MediaTools

/// The update from build 13 is the one thing that cannot be retried on a real
/// phone: a stored session that fails to load is a person signed out.
@MainActor
final class AuthUpdateMigrationTests: XCTestCase {
    /// Exactly what build 13's Keychain store wrote: plain JSONEncoder dates as
    /// seconds since 2001, the session's snake_case keys, and the provider fields.
    private let build13SessionJSON = """
    {
      "pair": {
        "session_id": "session-a",
        "user_id": "c0a80101-0000-4000-8000-000000000001",
        "access_token": "mta_at_stored",
        "access_expires_at": 700000000,
        "refresh_token": "mta_rt_stored",
        "inactive_expires_at": 900000000
      },
      "source": "clerk",
      "verifiedClerkID": "user_2abcLegacy"
    }
    """
    private let serverOwnerID = "c0a80101-0000-4000-8000-000000000001"
    private let clerkOwnerID = "user_2abcLegacy"

    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "AuthUpdateMigrationTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    private func build13Session() throws -> StoredDeviceSession {
        try JSONDecoder().decode(StoredDeviceSession.self, from: Data(build13SessionJSON.utf8))
    }

    private func controller(
        store: UpdateSessionStore,
        transport: any DeviceSessionTransport = RefreshingTransport(),
        retired: UpdateRetiredIdentities? = nil
    ) -> DeviceSessionController {
        DeviceSessionController(
            transport: transport,
            baseURL: URL(string: "https://example.test/api/v1")!,
            store: store,
            retiredLegacyIdentities: retired ?? UpdateRetiredIdentities()
        )
    }

    func testBuild13SessionDecodesOpensAndConvertsWithoutTheNetwork() throws {
        let decoded = try build13Session()
        XCTAssertEqual(decoded.source, .clerk)
        XCTAssertEqual(decoded.verifiedClerkID, clerkOwnerID)

        let store = UpdateSessionStore(decoded)
        let session = controller(store: store, transport: FailingTransport())

        XCTAssertEqual(session.activeUserID, serverOwnerID)
        XCTAssertEqual(store.value?.source, .passkey)
        XCTAssertNil(store.value?.verifiedClerkID)
        XCTAssertEqual(store.value?.pair.refreshToken, "mta_rt_stored")
        // The provider ID survives where recordings can still be found by it.
        XCTAssertEqual(store.localOwnerID(for: clerkOwnerID), serverOwnerID)
        XCTAssertEqual(session.verifiedMigration?.clerkID, clerkOwnerID)
        XCTAssertEqual(session.verifiedMigration?.userID, serverOwnerID)
    }

    func testConvertedSessionStillDecodesAfterASecondUpdateOrRollback() throws {
        let store = UpdateSessionStore(try build13Session())
        _ = controller(store: store, transport: FailingTransport())

        let saved = try JSONEncoder().encode(try XCTUnwrap(store.value))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertEqual(object["source"] as? String, "passkey")
        XCTAssertNil(object["verifiedClerkID"])
        let reloaded = try JSONDecoder().decode(StoredDeviceSession.self, from: saved)
        XCTAssertEqual(reloaded, store.value)
    }

    func testAnUnknownFutureSourceIsNotASignOut() throws {
        let future = build13SessionJSON
            .replacingOccurrences(of: "\"source\": \"clerk\"", with: "\"source\": \"sso\"")
            .replacingOccurrences(of: ",\n  \"verifiedClerkID\": \"user_2abcLegacy\"", with: "")
        let decoded = try JSONDecoder().decode(StoredDeviceSession.self, from: Data(future.utf8))
        XCTAssertEqual(decoded.source, .passkey)
    }

    func testAFailedSaveKeepsTheSessionUsableAndConvertsAgainLater() throws {
        let store = UpdateSessionStore(try build13Session())
        store.failsSaves = true
        let retired = UpdateRetiredIdentities()
        let session = controller(store: store, transport: FailingTransport(), retired: retired)

        XCTAssertEqual(session.activeUserID, serverOwnerID)
        XCTAssertEqual(store.value?.source, .clerk, "Nothing was written, so the next launch converts")

        store.failsSaves = false
        let relaunched = controller(store: store, transport: FailingTransport(), retired: retired)
        XCTAssertEqual(relaunched.activeUserID, serverOwnerID)
        XCTAssertEqual(store.value?.source, .passkey)
    }

    func testRefreshAfterConversionKeepsTheSameAccount() async throws {
        let store = UpdateSessionStore(try build13Session())
        let transport = RefreshingTransport()
        let session = controller(store: store, transport: transport)

        let token = try await session.accessToken(expectedOwnerID: serverOwnerID, forceRefresh: true)

        XCTAssertEqual(token, "mta_at_refreshed")
        XCTAssertEqual(store.value?.pair.userID, serverOwnerID)
        XCTAssertEqual(store.value?.pair.sessionID, "session-a")
        XCTAssertEqual(store.value?.source, .passkey)
        XCTAssertNil(store.value?.pendingNextRefreshToken)
        let rotations = await transport.rotations
        XCTAssertEqual(rotations.first?["refresh_token"], "mta_rt_stored")
    }

    /// The whole path Leon's iPhone takes: stored session, recording and consent
    /// keyed by the provider ID, then the same steps ContentView runs.
    func testBuild13UpdateKeepsRecordingsAndConsentThroughRefresh() async throws {
        let recordingStore = try RecordingStore(rootDirectory: directory.appendingPathComponent("recordings"))
        let recorder = RecordingCoordinator(
            store: recordingStore,
            simulatesCapture: true,
            activityManager: QuietActivities(),
            localAccountDefaults: defaults,
            availableCapacity: { _ in 10 * 1_024 * 1_024 * 1_024 },
            shareInbox: try ShareInboxStore(rootURL: directory.appendingPathComponent("inbox"))
        )
        let consent = AIProcessingConsentManager(defaults: defaults)
        let uploader = RecordingUploadCoordinator(
            recorder: recorder,
            service: UnreachableRecordingService(),
            watchStore: try TranscriptionWatchStore(rootDirectory: directory.appendingPathComponent("watches")),
            localAccountDefaults: defaults,
            aiProcessingConsent: consent,
            isForeground: { true }
        )

        // State build 13 left behind, under the provider ID.
        recorder.setActiveOwnerID(clerkOwnerID)
        consent.setActiveOwnerID(clerkOwnerID)
        consent.allow()
        consent.setAutoTranscribeEnabled(false)
        recorder.start(contentType: "voice_memo")
        recorder.stop()
        let recordingID = try XCTUnwrap(recorder.pendingRecordings.first?.id)
        XCTAssertEqual(recorder.recording(withID: recordingID)?.ownerID, clerkOwnerID)
        recorder.setActiveOwnerID(nil)
        consent.setActiveOwnerID(nil)

        // First launch of the new build.
        let store = UpdateSessionStore(try build13Session())
        let session = controller(store: store)
        let migration = try XCTUnwrap(session.verifiedMigration)
        try await uploader.migrateOwnerID(from: migration.clerkID, to: migration.userID)
        consent.migrateConsent(from: migration.clerkID, to: migration.userID)
        let owner = await session.activate()
        XCTAssertEqual(owner, serverOwnerID)
        consent.setActiveOwnerID(owner)
        await uploader.setActiveOwnerID(owner)

        _ = try await session.accessToken(expectedOwnerID: serverOwnerID, forceRefresh: true)

        XCTAssertEqual(recorder.recording(withID: recordingID)?.ownerID, serverOwnerID)
        XCTAssertEqual(recorder.availableRecordings.map(\.id), [recordingID])
        let file = try XCTUnwrap(recorder.fileURL(for: try XCTUnwrap(recorder.recording(withID: recordingID))))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(consent.hasConsent(ownerID: serverOwnerID))
        XCTAssertFalse(consent.isAutoTranscribeEnabled(ownerID: serverOwnerID), "A saved choice carries over")
        XCTAssertFalse(consent.hasConsent(ownerID: clerkOwnerID))
        XCTAssertEqual(session.activeUserID, serverOwnerID)
    }

    func testARetiredIdentityFromBuild13StaysSignedOutAndRevokesOnNextActivation() async throws {
        let store = UpdateSessionStore(try build13Session())
        let retired = UpdateRetiredIdentities()
        retired.values = [clerkOwnerID]
        let session = controller(store: store, transport: RevokingTransport(), retired: retired)

        XCTAssertNil(session.activeUserID)
        XCTAssertEqual(store.value?.pendingRevocation, true)
        XCTAssertTrue(retired.values.isEmpty)
        XCTAssertEqual(store.localOwnerID(for: clerkOwnerID), serverOwnerID)

        let owner = await session.activate()
        XCTAssertNil(owner)
        XCTAssertNil(store.value, "The sign-out build 13 started finishes here")
        XCTAssertEqual(store.localOwnerID(for: clerkOwnerID), serverOwnerID, "Its recordings stay reachable")
    }

    func testServerVerifiedIdentityReconnectsRecordingsFromBeforeAnyDeviceSession() throws {
        let pair = DeviceSessionPair(
            sessionID: "session-b", userID: serverOwnerID, accessToken: "access",
            accessExpiresAt: .distantFuture, refreshToken: "refresh", inactiveExpiresAt: .distantFuture
        )
        let store = UpdateSessionStore(StoredDeviceSession(pair: pair, source: .passkey))
        let session = controller(store: store, transport: FailingTransport())
        XCTAssertNil(session.verifiedMigration)

        session.adoptServerVerifiedLegacyIdentity(clerkOwnerID, ownerID: "someone-else")
        XCTAssertNil(session.verifiedMigration, "The mapping must name the signed-in account")

        session.adoptServerVerifiedLegacyIdentity(clerkOwnerID, ownerID: serverOwnerID)
        XCTAssertEqual(session.verifiedMigration?.clerkID, clerkOwnerID)
    }

    // MARK: Build 13's bootstrap journal

    /// Exactly what build 13 wrote before its bootstrap request.
    private func build13Journal() throws -> PendingDeviceSessionBootstrap {
        try JSONDecoder().decode(
            PendingDeviceSessionBootstrap.self,
            from: Data(#"{"verifiedClerkID":"user_2abcLegacy","nextRefreshToken":"mta_rt_journaled"}"#.utf8)
        )
    }

    func testALostBootstrapResponseRecoversInsteadOfSigningOut() async throws {
        let store = UpdateSessionStore(nil)
        store.journal = try build13Journal()
        let transport = ScriptedSessionTransport()
        let session = controller(store: store, transport: transport)
        XCTAssertNil(session.activeUserID, "Nothing is known until the server answers")

        let owner = await session.activate()

        XCTAssertEqual(owner, serverOwnerID)
        XCTAssertFalse(session.isAwaitingSessionRecovery)
        let sent = try XCTUnwrap(transport.bodies.first)
        XCTAssertEqual(transport.paths, ["/api/v1/auth/session/refresh"])
        XCTAssertEqual(sent["refresh_token"], "mta_rt_journaled")
        XCTAssertEqual(store.value?.pair.refreshToken, sent["next_refresh_token"])
        XCTAssertEqual(store.value?.source, .passkey, "A value older builds can read")
        XCTAssertNil(store.value?.pendingRevocation)
        XCTAssertNil(store.journal, "Used once, and now the session has moved on")
        XCTAssertEqual(store.localOwnerID(for: clerkOwnerID), serverOwnerID)
        XCTAssertEqual(session.verifiedMigration?.clerkID, clerkOwnerID, "Recordings under the old ID still connect")
    }

    func testRecoveryOfflineDoesNotShowSignInAndRepeatsTheSameRotation() async throws {
        let store = UpdateSessionStore(nil)
        store.journal = try build13Journal()
        let transport = ScriptedSessionTransport()
        transport.script = [.failure(URLError(.notConnectedToInternet))]
        let session = controller(store: store, transport: transport)

        let offline = await session.activate()

        XCTAssertNil(offline)
        XCTAssertTrue(session.isAwaitingSessionRecovery, "This must not read as signed out")
        XCTAssertFalse(session.needsSignIn)
        XCTAssertEqual(store.journal?.nextRefreshToken, "mta_rt_journaled")
        let successor = try XCTUnwrap(store.journal?.recoverySuccessorToken)

        let online = await session.activate()

        XCTAssertEqual(online, serverOwnerID)
        XCTAssertEqual(transport.bodies.count, 2)
        XCTAssertEqual(transport.bodies[1]["refresh_token"], "mta_rt_journaled")
        XCTAssertEqual(transport.bodies[1]["next_refresh_token"], successor, "A lost response must retry the same pair")
        XCTAssertFalse(session.isAwaitingSessionRecovery)
    }

    func testAServerFaultDuringRecoveryIsNotASignOut() async throws {
        let store = UpdateSessionStore(nil)
        store.journal = try build13Journal()
        let transport = ScriptedSessionTransport()
        transport.script = [.status(503)]
        let session = controller(store: store, transport: transport)

        let owner = await session.activate()

        XCTAssertNil(owner)
        XCTAssertTrue(session.isAwaitingSessionRecovery)
        XCTAssertNotNil(store.journal)
    }

    func testAJournalTheServerNeverCommittedEndsAtSignIn() async throws {
        for status in [400, 401, 409] {
            let store = UpdateSessionStore(nil)
            store.journal = try build13Journal()
            let transport = ScriptedSessionTransport()
            transport.script = [.status(status)]
            let session = controller(store: store, transport: transport)

            let owner = await session.activate()

            XCTAssertNil(owner)
            XCTAssertFalse(session.isAwaitingSessionRecovery, "HTTP \(status) leaves nothing to wait for")
            XCTAssertNil(store.journal)
            XCTAssertNil(store.value)
        }
    }

    func testAJournalIsNeverSentWhenASessionExists() async throws {
        let store = UpdateSessionStore(try build13Session())
        store.journal = try build13Journal()

        // The transport would fail this test if startup used the journal: its token
        // may have rotated already, and the server revokes a device for reuse.
        let transport = ScriptedSessionTransport()
        let session = controller(store: store, transport: transport)

        XCTAssertEqual(session.activeUserID, serverOwnerID)
        XCTAssertNil(store.journal)
        XCTAssertTrue(transport.bodies.isEmpty)
    }

    func testRecordedSignOutIntentRecoversOnlyToRevoke() async throws {
        let store = UpdateSessionStore(nil)
        store.journal = try build13Journal()
        let retired = UpdateRetiredIdentities()
        retired.values = [clerkOwnerID]
        let transport = ScriptedSessionTransport()
        let session = controller(store: store, transport: transport, retired: retired)

        let owner = await session.activate()

        XCTAssertNil(owner, "A sign-out build 13 started must not reopen a workspace")
        XCTAssertNil(session.activeUserID)
        XCTAssertFalse(session.isAwaitingSessionRecovery, "Sign-in is exactly what this person should see")
        XCTAssertEqual(transport.paths.last, "/api/v1/auth/sessions/session-a", "The recovered session is revoked")
        XCTAssertNil(store.value)
        XCTAssertNil(store.journal)
        XCTAssertTrue(retired.values.isEmpty)
    }

    func testRecordedSignOutIntentOfflineShowsSignInAndKeepsTheJournalToRevokeLater() async throws {
        let store = UpdateSessionStore(nil)
        store.journal = try build13Journal()
        let retired = UpdateRetiredIdentities()
        retired.values = [clerkOwnerID]
        let transport = ScriptedSessionTransport()
        transport.script = [.failure(URLError(.notConnectedToInternet))]
        let session = controller(store: store, transport: transport, retired: retired)

        let owner = await session.activate()

        XCTAssertNil(owner)
        XCTAssertFalse(session.isAwaitingSessionRecovery)
        XCTAssertNotNil(store.journal)
        XCTAssertEqual(retired.values, [clerkOwnerID])
    }

    func testASaveThatFailsDuringRecoveryKeepsTheCredentialAndRetries() async throws {
        let store = UpdateSessionStore(nil)
        store.journal = try build13Journal()
        store.failsSaves = true
        let transport = ScriptedSessionTransport()
        let session = controller(store: store, transport: transport)

        let failed = await session.activate()

        XCTAssertNil(failed)
        XCTAssertTrue(session.isAwaitingSessionRecovery)
        let successor = try XCTUnwrap(store.journal?.recoverySuccessorToken, "This is now the only copy of the session")

        store.failsSaves = false
        let owner = await session.activate()

        XCTAssertEqual(owner, serverOwnerID)
        XCTAssertEqual(transport.bodies.last?["next_refresh_token"], successor)
        XCTAssertEqual(store.value?.pair.refreshToken, successor)
    }

    func testALockedJournalIsNotASignOut() async throws {
        let store = UpdateSessionStore(nil)
        store.journalIsLocked = true
        let transport = ScriptedSessionTransport()
        let session = controller(store: store, transport: transport)

        let owner = await session.activate()

        XCTAssertNil(owner)
        XCTAssertTrue(session.isSessionStoreUnavailable)
        XCTAssertTrue(transport.bodies.isEmpty)
    }

    func testSigningInWhileAJournalWaitsReplacesIt() async throws {
        let store = UpdateSessionStore(nil)
        store.journal = try build13Journal()
        let session = controller(store: store, transport: FailingTransport())
        _ = await session.activate()
        XCTAssertTrue(session.isAwaitingSessionRecovery)

        try session.saveSession(
            pair: DeviceSessionPair(
                sessionID: "session-b", userID: serverOwnerID, accessToken: "access",
                accessExpiresAt: .distantFuture, refreshToken: "refresh", inactiveExpiresAt: .distantFuture
            ),
            source: .passkey
        )

        XCTAssertNil(store.journal)
        XCTAssertFalse(session.isAwaitingSessionRecovery)
        XCTAssertEqual(session.activeUserID, serverOwnerID)
    }

    // MARK: Recordings saved under the retired provider

    func testReconnectOnlyMovesRecordingsTheServerSaysAreThisAccounts() async throws {
        func profile(id: String, clerkID: String?) -> AccountProfile {
            AccountProfile(id: id, email: "owner@example.com", name: "Owner", clerkId: clerkID)
        }
        let owners: Set<String> = [clerkOwnerID]

        let matched = await LegacyRecordingReconnect.run(
            ownerID: serverOwnerID, legacyOwners: owners,
            profile: { profile(id: serverOwnerID, clerkID: clerkOwnerID) }
        )
        XCTAssertEqual(matched, .belongsHere(clerkID: clerkOwnerID))

        let otherProvider = await LegacyRecordingReconnect.run(
            ownerID: serverOwnerID, legacyOwners: owners,
            profile: { profile(id: serverOwnerID, clerkID: "user_someoneElse") }
        )
        XCTAssertEqual(otherProvider, .belongsElsewhere, "Another account's work is not a failure to report")

        let noProvider = await LegacyRecordingReconnect.run(
            ownerID: serverOwnerID, legacyOwners: owners,
            profile: { profile(id: serverOwnerID, clerkID: nil) }
        )
        XCTAssertEqual(noProvider, .belongsElsewhere)

        let wrongAccount = await LegacyRecordingReconnect.run(
            ownerID: serverOwnerID, legacyOwners: owners,
            profile: { profile(id: "someone-else", clerkID: clerkOwnerID) }
        )
        XCTAssertEqual(wrongAccount, .couldNotCheck)

        let offline = await LegacyRecordingReconnect.run(
            ownerID: serverOwnerID, legacyOwners: owners,
            profile: { throw URLError(.notConnectedToInternet) }
        )
        XCTAssertEqual(offline, .couldNotCheck, "Offline must be shown and retried, never dropped")
    }

    func testMissingKeychainItemOnlyMeansSignedOutWhenTrulyMissing() {
        let session = controller(store: UpdateSessionStore(nil), transport: FailingTransport())
        XCTAssertNil(session.activeUserID)
        XCTAssertFalse(session.isSessionStoreUnavailable)
    }
}

@MainActor
final class UpdateSessionStore: DeviceSessionStoring {
    var value: StoredDeviceSession?
    var failsSaves = false
    var journal: PendingDeviceSessionBootstrap?
    var journalIsLocked = false
    private var ownerMappings: [String: String] = [:]

    init(_ value: StoredDeviceSession?) { self.value = value }
    func load() -> StoredDeviceSession? { value }
    func save(_ value: StoredDeviceSession) throws {
        if failsSaves { throw CocoaError(.fileWriteUnknown) }
        self.value = value
    }
    func delete() {
        value = nil
        journal = nil
    }
    func loadPendingBootstrap() -> PendingBootstrapLoadResult {
        if journalIsLocked { return .unavailable }
        return journal.map(PendingBootstrapLoadResult.found) ?? .missing
    }
    func savePendingBootstrap(_ value: PendingDeviceSessionBootstrap) throws { journal = value }
    func deletePendingBootstrap() { journal = nil }
    func localOwnerID(for clerkID: String) -> String? { ownerMappings[clerkID] }
    func clerkID(forLocalOwnerID ownerID: String) -> String? {
        ownerMappings.first { $0.value == ownerID }?.key
    }
    func saveLocalOwnerID(_ ownerID: String, for clerkID: String) { ownerMappings[clerkID] = ownerID }
    func removeLocalOwnerID(for clerkID: String) { ownerMappings[clerkID] = nil }
}

@MainActor
final class UpdateRetiredIdentities: RetiredLegacyIdentityStoring {
    var values: Set<String> = []
    func contains(_ clerkID: String) -> Bool { values.contains(clerkID) }
    func removeAll() { values.removeAll() }
}

/// Answers each refresh as the server would, unless told otherwise for that attempt.
private final class ScriptedSessionTransport: DeviceSessionTransport, @unchecked Sendable {
    enum Step {
        case failure(Error)
        case status(Int)
    }

    var script: [Step] = []
    private(set) var bodies: [[String: String]] = []
    private(set) var paths: [String] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        paths.append(request.url?.path ?? "")
        guard request.url?.path.hasSuffix("/auth/session/refresh") == true else {
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        }
        let values = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String]
        )
        bodies.append(values)
        if !script.isEmpty {
            switch script.removeFirst() {
            case .failure(let error):
                throw error
            case .status(let status):
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }
        return try refreshResponse(for: request, next: values["next_refresh_token"] ?? "")
    }
}

private struct FailingTransport: DeviceSessionTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

private struct RevokingTransport: DeviceSessionTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if request.url?.path.hasSuffix("/auth/session/refresh") == true {
            let body = try XCTUnwrap(request.httpBody)
            let values = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            return try refreshResponse(for: request, next: values["next_refresh_token"] ?? "")
        }
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
    }
}

private func refreshResponse(for request: URLRequest, next: String) throws -> (Data, URLResponse) {
    let body = try JSONSerialization.data(withJSONObject: [
        "session_id": "session-a",
        "user_id": "c0a80101-0000-4000-8000-000000000001",
        "access_token": "mta_at_refreshed",
        "access_expires_at": "2099-01-01T00:00:00Z",
        "refresh_token": next,
        "inactive_expires_at": "2099-01-01T00:00:00Z",
    ])
    return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
}

private actor RefreshingTransport: DeviceSessionTransport {
    private(set) var rotations: [[String: String]] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let body = try XCTUnwrap(request.httpBody)
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        rotations.append(values)
        return try refreshResponse(for: request, next: values["next_refresh_token"] ?? "")
    }
}

@MainActor
private final class QuietActivities: RecordingActivityManaging {
    let areActivitiesEnabled = true
    func start(for recording: LocalRecording) async throws {}
    func update(recordingID: UUID, isPaused: Bool, isInterrupted: Bool, duration: TimeInterval) async {}
    func end(recordingID: UUID?, finalDuration: TimeInterval) async {}
}

@MainActor
private final class UnreachableRecordingService: RecordingUploadServicing {
    func getAudioItem(_ id: String, expectedOwnerID: String?) async throws -> AudioTranscription {
        throw URLError(.notConnectedToInternet)
    }
    func uploadAudio(fileURL: URL, filename: String, mimeType: String, contentType: String, expectedOwnerID: String?) async throws -> AudioTranscription {
        throw URLError(.notConnectedToInternet)
    }
    func presignAudioUpload(filename: String, mimeType: String, sizeBytes: Int64, expectedOwnerID: String?) async throws -> AudioUploadPresignResponse {
        throw URLError(.notConnectedToInternet)
    }
    func completeAudioUpload(_ completion: AudioUploadCompleteRequest, expectedOwnerID: String?) async throws -> AudioTranscription {
        throw URLError(.notConnectedToInternet)
    }
    func importSharedLink(_ link: String, expectedOwnerID: String?) async throws {}
    func importSharedPDF(fileURL: URL, filename: String, expectedOwnerID: String?) async throws {}
}
