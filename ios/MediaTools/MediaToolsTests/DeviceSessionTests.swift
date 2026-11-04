import XCTest
@testable import MediaTools

@MainActor
private final class MemoryDeviceSessionStore: DeviceSessionStoring {
    var value: StoredDeviceSession?
    private var ownerMappings: [String: String] = [:]
    init(_ value: StoredDeviceSession?) { self.value = value }
    func load() -> StoredDeviceSession? { value }
    func save(_ value: StoredDeviceSession) throws { self.value = value }
    func delete() { value = nil }
    func localOwnerID(for clerkID: String) -> String? { ownerMappings[clerkID] }
    func clerkID(forLocalOwnerID ownerID: String) -> String? {
        ownerMappings.first(where: { $0.value == ownerID })?.key
    }
    func saveLocalOwnerID(_ ownerID: String, for clerkID: String) {
        ownerMappings[clerkID] = ownerID
    }
    func removeLocalOwnerID(for clerkID: String) { ownerMappings.removeValue(forKey: clerkID) }
}

/// A Keychain that cannot answer until the iPhone is unlocked.
@MainActor
private final class LockableDeviceSessionStore: DeviceSessionStoring {
    var isLocked = true
    var value: StoredDeviceSession?
    init(_ value: StoredDeviceSession?) { self.value = value }
    func load() -> StoredDeviceSession? { isLocked ? nil : value }
    func loadResult() -> DeviceSessionLoadResult {
        if isLocked { return .unavailable }
        return value.map(DeviceSessionLoadResult.found) ?? .missing
    }
    func save(_ value: StoredDeviceSession) throws { self.value = value }
    func delete() { value = nil }
    func localOwnerID(for clerkID: String) -> String? { nil }
    func clerkID(forLocalOwnerID ownerID: String) -> String? { nil }
    func saveLocalOwnerID(_ ownerID: String, for clerkID: String) {}
    func removeLocalOwnerID(for clerkID: String) {}
}

private struct UnreachableDeviceSessionTransport: DeviceSessionTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        XCTFail("Startup must not reach the network: \(request)")
        throw URLError(.notConnectedToInternet)
    }
}

@MainActor
private final class MemoryRetiredIdentityStore: RetiredLegacyIdentityStoring {
    var values: Set<String> = []
    func contains(_ clerkID: String) -> Bool { values.contains(clerkID) }
    func removeAll() { values.removeAll() }
}

private actor RecoveringDeviceSessionTransport: DeviceSessionTransport {
    private var requestBodies: [[String: String]] = []
    private var failFirstResponse = true

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let body = try XCTUnwrap(request.httpBody)
        let values = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        requestBodies.append(values)
        if failFirstResponse {
            failFirstResponse = false
            throw URLError(.timedOut)
        }
        let responseBody: [String: String] = [
            "session_id": "session-a",
            "user_id": "server-a",
            "access_token": "mta_at_recovered",
            "access_expires_at": "2027-09-29T00:00:00Z",
            "refresh_token": values["next_refresh_token"] ?? "",
            "inactive_expires_at": "2027-09-29T00:00:00Z",
        ]
        let data = try JSONSerialization.data(withJSONObject: responseBody)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200,
                                      httpVersion: nil, headerFields: nil)!)
    }

    func bodies() -> [[String: String]] { requestBodies }
}

private actor RevocationDeviceSessionTransport: DeviceSessionTransport {
    private var shouldFail = true
    init(shouldFail: Bool = true) { self.shouldFail = shouldFail }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let status = shouldFail ? 503 : 204
        shouldFail = false
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: status,
                                        httpVersion: nil, headerFields: nil)!)
    }
}

private actor DisabledSessionTransport: DeviceSessionTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404,
                                        httpVersion: nil, headerFields: nil)!)
    }
}

private actor UnauthorizedDeviceSessionTransport: DeviceSessionTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 401,
                                        httpVersion: nil, headerFields: nil)!)
    }
}

private actor DelayedUnauthorizedTransport: DeviceSessionTransport {
    private var pending: CheckedContinuation<(Data, URLResponse), Error>?
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var requestURL: URL?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            requestURL = request.url
            pending = continuation
            requestWaiter?.resume()
            requestWaiter = nil
        }
    }

    func waitForRequest() async {
        if pending != nil { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }

    func reject() {
        let response = HTTPURLResponse(url: requestURL!, statusCode: 401,
                                       httpVersion: nil, headerFields: nil)!
        pending?.resume(returning: (Data(), response))
        pending = nil
    }
}

final class DeviceSessionTests: XCTestCase {
    @MainActor
    func testRefreshRetriesSameJournaledRotationAfterLostResponse() async throws {
        let oldPair = DeviceSessionPair(
            sessionID: "session-a",
            userID: "server-a",
            accessToken: "mta_at_expired",
            accessExpiresAt: .distantPast,
            refreshToken: "mta_rt_old",
            inactiveExpiresAt: .distantFuture
        )
        let store = MemoryDeviceSessionStore(
            StoredDeviceSession(pair: oldPair, verifiedClerkID: "clerk-a",
                                pendingNextRefreshToken: nil)
        )
        let transport = RecoveringDeviceSessionTransport()
        let controller = DeviceSessionController(
            transport: transport,
            baseURL: URL(string: "https://example.test/api/v1")!,
            store: store
        )

        do {
            _ = try await controller.accessToken(expectedOwnerID: "server-a", forceRefresh: false)
            XCTFail("Expected the simulated lost response")
        } catch is URLError {
            // The next token must be durable before the network request.
        }
        let pending = try XCTUnwrap(store.value?.pendingNextRefreshToken)
        XCTAssertTrue(pending.hasPrefix("mta_rt_"))
        XCTAssertEqual(pending.count, 50)
        XCTAssertEqual(store.value?.pair.refreshToken, "mta_rt_old")

        let recovered = try await controller.accessToken(
            expectedOwnerID: "server-a", forceRefresh: false
        )
        XCTAssertEqual(recovered, "mta_at_recovered")
        XCTAssertEqual(store.value?.pair.refreshToken, pending)
        XCTAssertNil(store.value?.pendingNextRefreshToken)
        let bodies = await transport.bodies()
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0]["refresh_token"], bodies[1]["refresh_token"])
        XCTAssertEqual(bodies[0]["next_refresh_token"], bodies[1]["next_refresh_token"])
    }

    @MainActor
    func testDeviceCredentialRejectsAnotherLocalOwner() async throws {
        let pair = DeviceSessionPair(
            sessionID: "session-a", userID: "server-a", accessToken: "mta_at_valid",
            accessExpiresAt: .distantFuture, refreshToken: "mta_rt_valid",
            inactiveExpiresAt: .distantFuture
        )
        let controller = DeviceSessionController(
            store: MemoryDeviceSessionStore(
                StoredDeviceSession(pair: pair, verifiedClerkID: "clerk-a",
                                    pendingNextRefreshToken: nil)
            )
        )
        do {
            _ = try await controller.accessToken(expectedOwnerID: "server-b", forceRefresh: false)
            XCTFail("A different owner must not use this device credential")
        } catch APIError.authenticationRequired {
            // Expected account isolation.
        }
    }

    @MainActor
    func testSignOutRetainsCredentialUntilServerConfirmsRevocation() async throws {
        let pair = DeviceSessionPair(
            sessionID: "session-a", userID: "server-a", accessToken: "mta_at_valid",
            accessExpiresAt: .distantFuture, refreshToken: "mta_rt_valid",
            inactiveExpiresAt: .distantFuture
        )
        let store = MemoryDeviceSessionStore(
            StoredDeviceSession(pair: pair, verifiedClerkID: "clerk-a",
                                pendingNextRefreshToken: nil)
        )
        let controller = DeviceSessionController(
            transport: RevocationDeviceSessionTransport(),
            baseURL: URL(string: "https://example.test/api/v1")!,
            store: store
        )

        do {
            try await controller.revokeAndClear()
            XCTFail("A failed DELETE must not discard the revocation credential")
        } catch APIError.httpError(503, _, _) {
            XCTAssertEqual(store.value?.pair, pair)
        }
        try await controller.revokeAndClear()
        XCTAssertNil(store.value)
    }

    @MainActor
    func testSignOutRetainsCredentialWhenSessionRoutesAreUnavailable() async throws {
        let pair = DeviceSessionPair(
            sessionID: "session-a", userID: "server-a", accessToken: "mta_at_valid",
            accessExpiresAt: .distantFuture, refreshToken: "mta_rt_valid",
            inactiveExpiresAt: .distantFuture
        )
        let store = MemoryDeviceSessionStore(
            StoredDeviceSession(pair: pair, verifiedClerkID: "clerk-a",
                                pendingNextRefreshToken: nil)
        )
        let controller = DeviceSessionController(
            transport: DisabledSessionTransport(),
            baseURL: URL(string: "https://example.test/api/v1")!,
            store: store
        )

        do {
            try await controller.revokeAndClear()
            XCTFail("A missing route does not confirm that the session was revoked")
        } catch APIError.httpError(404, _, _) {
            XCTAssertEqual(store.value?.pair, pair)
        }
    }

    @MainActor
    func testUnavailableRevocationSuspendsDeviceAccessAndRetriesLater() async throws {
        let pair = DeviceSessionPair(
            sessionID: "session-a", userID: "server-a", accessToken: "mta_at_valid",
            accessExpiresAt: .distantFuture, refreshToken: "mta_rt_valid",
            inactiveExpiresAt: .distantFuture
        )
        let store = MemoryDeviceSessionStore(
            StoredDeviceSession(pair: pair, verifiedClerkID: "clerk-a",
                                pendingNextRefreshToken: nil)
        )
        let controller = DeviceSessionController(
            transport: RevocationDeviceSessionTransport(),
            baseURL: URL(string: "https://example.test/api/v1")!,
            store: store
        )

        try await controller.revokeOrSuspend()
        XCTAssertEqual(store.value?.pendingRevocation, true)
        let suspendedToken = try await controller.accessToken(
            expectedOwnerID: "server-a", forceRefresh: false
        )
        XCTAssertNil(suspendedToken)

        let restoredOwner = await controller.activate()
        XCTAssertNil(restoredOwner)
        XCTAssertNil(store.value)
    }

    @MainActor
    func testNativePasskeySessionPersistsWithoutClerk() async throws {
        let pair = DeviceSessionPair(
            sessionID: "session-passkey", userID: "server-native", accessToken: "mta_at_native",
            accessExpiresAt: .distantFuture, refreshToken: "mta_rt_native",
            inactiveExpiresAt: .distantFuture
        )
        let store = MemoryDeviceSessionStore(nil)
        let controller = DeviceSessionController(store: store)

        try controller.saveSession(pair: pair, source: .passkey)
        let owner = await controller.activate()
        let token = try await controller.accessToken(expectedOwnerID: "server-native", forceRefresh: false)

        XCTAssertEqual(owner, "server-native")
        XCTAssertEqual(token, "mta_at_native")
        XCTAssertEqual(store.value?.source, .passkey)
        XCTAssertTrue(controller.hasNativeFirstPartySession)
        XCTAssertNil(controller.verifiedMigration)
    }

    @MainActor
    func testPrepareForNewNativeSessionRequiresRevocationBeforeContinuing() async throws {
        let pair = DeviceSessionPair(
            sessionID: "session-old", userID: "server-old", accessToken: "mta_at_old",
            accessExpiresAt: .distantFuture, refreshToken: "mta_rt_old",
            inactiveExpiresAt: .distantFuture
        )
        let store = MemoryDeviceSessionStore(
            StoredDeviceSession(pair: pair, source: .passkey, pendingNextRefreshToken: nil)
        )
        let controller = DeviceSessionController(
            transport: RevocationDeviceSessionTransport(shouldFail: false),
            baseURL: URL(string: "https://example.test/api/v1")!,
            store: store
        )

        try await controller.prepareForNewNativeSession()

        XCTAssertNil(store.value)
        XCTAssertNil(controller.activeUserID)
    }

    @MainActor
    func testPrepareForNewNativeSessionRejectsPendingRevocation() async throws {
        let pair = DeviceSessionPair(
            sessionID: "session-old", userID: "server-old", accessToken: "mta_at_old",
            accessExpiresAt: .distantFuture, refreshToken: "mta_rt_old",
            inactiveExpiresAt: .distantFuture
        )
        let store = MemoryDeviceSessionStore(
            StoredDeviceSession(pair: pair, source: .passkey, pendingNextRefreshToken: nil, pendingRevocation: true)
        )
        let controller = DeviceSessionController(store: store)

        do {
            try await controller.prepareForNewNativeSession()
            XCTFail("Suspended revocation credentials must block account switching")
        } catch APIError.authenticationRequired {
            XCTAssertEqual(store.value?.pendingRevocation, true)
        }
    }

    @MainActor
    func testReplacingSessionRevokesExistingCredentialBeforeSavingRecoverySession() async throws {
        let oldPair = DeviceSessionPair(
            sessionID: "session-old", userID: "server-old", accessToken: "mta_at_old",
            accessExpiresAt: .distantFuture, refreshToken: "mta_rt_old",
            inactiveExpiresAt: .distantFuture
        )
        let newPair = DeviceSessionPair(
            sessionID: "session-new", userID: "server-new", accessToken: "mta_at_new",
            accessExpiresAt: .distantFuture, refreshToken: "mta_rt_new",
            inactiveExpiresAt: .distantFuture
        )
        let store = MemoryDeviceSessionStore(
            StoredDeviceSession(pair: oldPair, verifiedClerkID: "clerk-old",
                                pendingNextRefreshToken: nil)
        )
        let controller = DeviceSessionController(
            transport: RevocationDeviceSessionTransport(shouldFail: false),
            baseURL: URL(string: "https://example.test/api/v1")!,
            store: store
        )

        try await controller.replaceSession(pair: newPair, source: .recoveryCode)

        XCTAssertEqual(store.value?.pair, newPair)
        XCTAssertEqual(store.value?.source, .recoveryCode)
        XCTAssertEqual(controller.activeUserID, "server-new")
    }

    @MainActor
    func testReplacingSessionRejectsSuspendedRevocationCredential() async throws {
        let oldPair = DeviceSessionPair(
            sessionID: "session-old", userID: "server-old", accessToken: "mta_at_old",
            accessExpiresAt: .distantFuture, refreshToken: "mta_rt_old",
            inactiveExpiresAt: .distantFuture
        )
        let newPair = DeviceSessionPair(
            sessionID: "session-new", userID: "server-new", accessToken: "mta_at_new",
            accessExpiresAt: .distantFuture, refreshToken: "mta_rt_new",
            inactiveExpiresAt: .distantFuture
        )
        let store = MemoryDeviceSessionStore(
            StoredDeviceSession(pair: oldPair, verifiedClerkID: "clerk-old",
                                pendingNextRefreshToken: nil, pendingRevocation: true)
        )
        let controller = DeviceSessionController(store: store)

        do {
            try await controller.replaceSession(pair: newPair, source: .passkey)
            XCTFail("A suspended credential must not be overwritten")
        } catch APIError.authenticationRequired {
            XCTAssertEqual(store.value?.pair, oldPair)
            XCTAssertEqual(store.value?.pendingRevocation, true)
        }
    }

    func testLegacyStoredClerkSessionDecodesWithClerkSource() throws {
        struct LegacyStoredDeviceSession: Encodable {
            var pair: DeviceSessionPair
            let verifiedClerkID: String
            var pendingNextRefreshToken: String?
        }
        let pair = DeviceSessionPair(
            sessionID: "session-a", userID: "server-a", accessToken: "mta_at_valid",
            accessExpiresAt: .distantFuture, refreshToken: "mta_rt_valid",
            inactiveExpiresAt: .distantFuture
        )
        let data = try JSONEncoder().encode(
            LegacyStoredDeviceSession(
                pair: pair,
                verifiedClerkID: "clerk-a",
                pendingNextRefreshToken: nil
            )
        )

        let decoded = try JSONDecoder().decode(StoredDeviceSession.self, from: data)

        XCTAssertEqual(decoded.source, .clerk)
        XCTAssertEqual(decoded.verifiedClerkID, "clerk-a")
        XCTAssertEqual(decoded.pair, pair)
    }

    @MainActor
    func testOldRefreshCannotInvalidateClearedSession() async throws {
        let pair = DeviceSessionPair(
            sessionID: "session-a", userID: "server-a", accessToken: "mta_at_expired",
            accessExpiresAt: .distantPast, refreshToken: "mta_rt_old",
            inactiveExpiresAt: .distantFuture
        )
        let transport = DelayedUnauthorizedTransport()
        let controller = DeviceSessionController(
            transport: transport,
            baseURL: URL(string: "https://example.test/api/v1")!,
            store: MemoryDeviceSessionStore(
                StoredDeviceSession(pair: pair, verifiedClerkID: "clerk-a",
                                    pendingNextRefreshToken: nil)
            )
        )
        let request = Task {
            try await controller.accessToken(expectedOwnerID: "server-a", forceRefresh: false)
        }
        await transport.waitForRequest()
        controller.clear()
        await transport.reject()

        do {
            _ = try await request.value
            XCTFail("A cleared refresh must not succeed")
        } catch is CancellationError {
            XCTAssertFalse(controller.needsSignIn)
        }
    }

}

@MainActor
final class DeviceSessionStartupTests: XCTestCase {
    private func storedSession(
        source: DeviceSessionSource = .passkey,
        verifiedClerkID: String? = nil,
        pendingRevocation: Bool? = nil,
        expiresIn: TimeInterval = 3_600
    ) -> StoredDeviceSession {
        StoredDeviceSession(
            pair: DeviceSessionPair(
                sessionID: "session-a",
                userID: "server-a",
                accessToken: "access",
                accessExpiresAt: Date().addingTimeInterval(expiresIn),
                refreshToken: "refresh",
                inactiveExpiresAt: Date().addingTimeInterval(86_400)
            ),
            source: source,
            verifiedClerkID: verifiedClerkID,
            pendingRevocation: pendingRevocation
        )
    }

    private func controller(
        store: any DeviceSessionStoring,
        retired: MemoryRetiredIdentityStore? = nil
    ) -> DeviceSessionController {
        DeviceSessionController(
            transport: UnreachableDeviceSessionTransport(),
            baseURL: URL(string: "https://example.invalid/api/v1")!,
            store: store,
            retiredLegacyIdentities: retired ?? MemoryRetiredIdentityStore()
        )
    }

    func testStoredSessionOpensTheWorkspaceBeforeAnyNetworkRequest() {
        let session = controller(store: MemoryDeviceSessionStore(storedSession()))
        XCTAssertEqual(session.activeUserID, "server-a")
    }

    func testExpiredAccessTokenStillOpensTheWorkspaceImmediately() {
        let session = controller(store: MemoryDeviceSessionStore(storedSession(expiresIn: -60)))
        XCTAssertEqual(session.activeUserID, "server-a")
    }

    func testStoredClerkSessionFromAnEarlierBuildStillOpens() throws {
        let legacy = Data("""
        {"pair":{"session_id":"session-a","user_id":"server-a","access_token":"access",\
        "access_expires_at":1000000000,"refresh_token":"refresh",\
        "inactive_expires_at":1000000000},"source":"clerk","verifiedClerkID":"clerk-a"}
        """.utf8)
        let decoded = try JSONDecoder().decode(StoredDeviceSession.self, from: legacy)
        XCTAssertEqual(decoded.source, .clerk)
        let session = controller(store: MemoryDeviceSessionStore(decoded))
        XCTAssertEqual(session.activeUserID, "server-a")
        XCTAssertEqual(session.verifiedMigration?.clerkID, "clerk-a")
    }

    func testRevokedAndRetiredSessionsDoNotOpen() {
        let revoked = controller(
            store: MemoryDeviceSessionStore(storedSession(pendingRevocation: true))
        )
        XCTAssertNil(revoked.activeUserID)

        let retiredIdentities = MemoryRetiredIdentityStore()
        retiredIdentities.values = ["clerk-a"]
        let store = MemoryDeviceSessionStore(
            storedSession(source: .clerk, verifiedClerkID: "clerk-a")
        )
        let retired = controller(store: store, retired: retiredIdentities)
        XCTAssertNil(retired.activeUserID)
        // An unfinished sign-out from build 13 stays a sign-out after the update.
        XCTAssertEqual(store.value?.pendingRevocation, true)
        XCTAssertNil(retired.verifiedMigration)
    }

    func testLockedKeychainIsNotASignedOutState() async {
        let store = LockableDeviceSessionStore(storedSession())
        let session = controller(store: store)

        XCTAssertTrue(session.isSessionStoreUnavailable)
        XCTAssertNil(session.activeUserID)
        let revision = session.sessionRevision

        // Still locked: nothing changes and nothing gets replaced.
        session.reloadStoredSessionIfUnavailable()
        XCTAssertTrue(session.isSessionStoreUnavailable)
        XCTAssertEqual(session.sessionRevision, revision)
        let owner = await session.activate()
        XCTAssertNil(owner)
        XCTAssertNotNil(store.value)

        // Foreground after unlock restores the same session without signing in.
        store.isLocked = false
        session.reloadStoredSessionIfUnavailable()
        XCTAssertFalse(session.isSessionStoreUnavailable)
        XCTAssertEqual(session.activeUserID, "server-a")
        XCTAssertEqual(session.sessionRevision, revision + 1)
    }

    func testLockedKeychainThatTurnsOutEmptyBecomesSignedOut() {
        let store = LockableDeviceSessionStore(nil)
        let session = controller(store: store)
        XCTAssertTrue(session.isSessionStoreUnavailable)

        store.isLocked = false
        session.reloadStoredSessionIfUnavailable()

        XCTAssertFalse(session.isSessionStoreUnavailable)
        XCTAssertNil(session.activeUserID)
    }

}
