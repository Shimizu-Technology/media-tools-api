import XCTest
@testable import MediaTools

@MainActor
private final class MemoryDeviceSessionStore: DeviceSessionStoring {
    var value: StoredDeviceSession?
    var pendingBootstrap: PendingDeviceSessionBootstrap?
    private var ownerMappings: [String: String] = [:]
    init(_ value: StoredDeviceSession?) { self.value = value }
    func load() -> StoredDeviceSession? { value }
    func save(_ value: StoredDeviceSession) throws { self.value = value }
    func delete() { value = nil }
    func loadPendingBootstrap() throws -> PendingDeviceSessionBootstrap? { pendingBootstrap }
    func savePendingBootstrap(_ value: PendingDeviceSessionBootstrap) throws { pendingBootstrap = value }
    func deletePendingBootstrap() { pendingBootstrap = nil }
    func localOwnerID(for clerkID: String) -> String? { ownerMappings[clerkID] }
    func clerkID(forLocalOwnerID ownerID: String) -> String? {
        ownerMappings.first(where: { $0.value == ownerID })?.key
    }
    func saveLocalOwnerID(_ ownerID: String, for clerkID: String) {
        ownerMappings[clerkID] = ownerID
    }
    func removeLocalOwnerID(for clerkID: String) { ownerMappings.removeValue(forKey: clerkID) }
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
    func testSuccessfulSignOutKeepsOwnerMappingForFlagRollbackAndRelaunch() async throws {
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
            transport: RevocationDeviceSessionTransport(shouldFail: false),
            baseURL: URL(string: "https://example.test/api/v1")!,
            store: store, enabled: true
        )
        try await controller.revokeAndClear()
        XCTAssertNil(store.value)
        let relaunched = DeviceSessionController(store: store, enabled: false)
        let signedOutOwner = await relaunched.activate(clerkID: nil)
        XCTAssertNil(signedOutOwner)
        let sameOwner = await relaunched.activate(clerkID: "clerk-a")
        XCTAssertEqual(sameOwner, "server-a")
        XCTAssertEqual(relaunched.clerkIDForFallbackOwner("server-a"), "clerk-a")
        let token = try await relaunched.accessToken(expectedOwnerID: "server-a", forceRefresh: false)
        XCTAssertNil(token)
        let otherOwner = await relaunched.activate(clerkID: "clerk-b")
        XCTAssertEqual(otherOwner, "clerk-b")
        relaunched.removeLocalOwnerMapping(clerkID: "clerk-a")
        XCTAssertEqual(relaunched.fallbackOwnerID(for: "clerk-a"), "clerk-a")
    }
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
            store: store,
            enabled: true
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
    func testClerkBootstrapRetriesSameJournaledSuccessorAfterLostResponse() async throws {
        let store = MemoryDeviceSessionStore(nil)
        let transport = RecoveringDeviceSessionTransport()
        let controller = DeviceSessionController(
            transport: transport,
            baseURL: URL(string: "https://example.test/api/v1")!,
            store: store,
            enabled: true
        )

        do {
            try await controller.bootstrapForTesting(verifiedClerkID: "clerk-a", clerkToken: "clerk_jwt_a")
            XCTFail("Expected the simulated lost bootstrap response")
        } catch is URLError {
            // The successor refresh token must already be durable.
        }

        let pending = try XCTUnwrap(store.pendingBootstrap)
        XCTAssertEqual(pending.verifiedClerkID, "clerk-a")
        XCTAssertTrue(pending.nextRefreshToken.hasPrefix("mta_rt_"))
        XCTAssertNil(store.value)

        try await controller.bootstrapForTesting(verifiedClerkID: "clerk-a", clerkToken: "clerk_jwt_a")

        XCTAssertEqual(store.value?.source, .clerk)
        XCTAssertEqual(store.value?.verifiedClerkID, "clerk-a")
        XCTAssertEqual(store.value?.pair.refreshToken, pending.nextRefreshToken)
        XCTAssertNil(store.pendingBootstrap)
        let bodies = await transport.bodies()
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0]["next_refresh_token"], pending.nextRefreshToken)
        XCTAssertEqual(bodies[1]["next_refresh_token"], pending.nextRefreshToken)
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
            ),
            enabled: true
        )
        do {
            _ = try await controller.accessToken(expectedOwnerID: "server-b", forceRefresh: false)
            XCTFail("A different owner must not use this device credential")
        } catch APIError.authenticationRequired {
            // Expected account isolation.
        }
    }

    @MainActor
    func testAccountSwitchSuspendsPreviousCredentialForRevocation() async throws {
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
            store: store,
            enabled: true
        )

        let owner = await controller.activate(clerkID: "clerk-b")

        XCTAssertEqual(owner, "clerk-b")
        XCTAssertEqual(store.value?.pair, pair)
        XCTAssertEqual(store.value?.pendingRevocation, true)
        XCTAssertEqual(controller.clerkIDForFallbackOwner("server-a"), "clerk-a")
        let token = try await controller.accessToken(
            expectedOwnerID: "server-a", forceRefresh: false
        )
        XCTAssertNil(token)
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
            store: store,
            enabled: true
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
            store: store,
            enabled: true
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
            store: store,
            enabled: true
        )

        try await controller.revokeOrSuspend()
        XCTAssertEqual(store.value?.pendingRevocation, true)
        let suspendedToken = try await controller.accessToken(
            expectedOwnerID: "server-a", forceRefresh: false
        )
        XCTAssertNil(suspendedToken)

        let restoredOwner = await controller.activate(clerkID: nil)
        XCTAssertNil(restoredOwner)
        XCTAssertNil(store.value)
    }

    @MainActor
    func testRollbackKeepsVerifiedLocalOwnerOnClerkFallback() async throws {
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
            store: store,
            enabled: true
        )

        try await controller.revokeOrSuspend()
        XCTAssertEqual(store.value?.pendingRevocation, true)
        let sameOwner = await controller.activate(clerkID: "clerk-a")
        XCTAssertEqual(sameOwner, "server-a")
        XCTAssertEqual(controller.clerkIDForFallbackOwner("server-a"), "clerk-a")
        let otherOwner = await controller.activate(clerkID: "clerk-b")
        XCTAssertEqual(otherOwner, "clerk-b")
    }

    @MainActor
    func testDisabledIOSFlagKeepsVerifiedLocalOwnerWithoutUsingDeviceToken() async throws {
        let pair = DeviceSessionPair(
            sessionID: "session-a", userID: "server-a", accessToken: "mta_at_valid",
            accessExpiresAt: .distantFuture, refreshToken: "mta_rt_valid",
            inactiveExpiresAt: .distantFuture
        )
        let controller = DeviceSessionController(
            store: MemoryDeviceSessionStore(
                StoredDeviceSession(pair: pair, verifiedClerkID: "clerk-a",
                                    pendingNextRefreshToken: nil)
            ),
            enabled: false
        )

        XCTAssertEqual(controller.fallbackOwnerID(for: "clerk-a"), "server-a")
        XCTAssertEqual(controller.fallbackOwnerID(for: "clerk-b"), "clerk-b")
        XCTAssertEqual(controller.clerkIDForFallbackOwner("server-a"), "clerk-a")
        let owner = await controller.activate(clerkID: "clerk-a")
        XCTAssertEqual(owner, "server-a")
        let token = try await controller.accessToken(expectedOwnerID: "server-a", forceRefresh: false)
        XCTAssertNil(token)
    }


    @MainActor
    func testNativePasskeySessionPersistsWithoutClerk() async throws {
        let pair = DeviceSessionPair(
            sessionID: "session-passkey", userID: "server-native", accessToken: "mta_at_native",
            accessExpiresAt: .distantFuture, refreshToken: "mta_rt_native",
            inactiveExpiresAt: .distantFuture
        )
        let store = MemoryDeviceSessionStore(nil)
        let controller = DeviceSessionController(store: store, enabled: true)

        try controller.saveSession(pair: pair, source: .passkey)
        let owner = await controller.activate(clerkID: nil)
        let token = try await controller.accessToken(expectedOwnerID: "server-native", forceRefresh: false)

        XCTAssertEqual(owner, "server-native")
        XCTAssertEqual(token, "mta_at_native")
        XCTAssertEqual(store.value?.source, .passkey)
        XCTAssertTrue(controller.hasNativeFirstPartySession)
        XCTAssertNil(controller.verifiedMigration)
    }

    @MainActor
    func testNativeSessionRemainsAuthoritativeWhenClerkIsLive() async throws {
        let pair = DeviceSessionPair(
            sessionID: "session-passkey", userID: "server-native", accessToken: "mta_at_native",
            accessExpiresAt: .distantFuture, refreshToken: "mta_rt_native",
            inactiveExpiresAt: .distantFuture
        )
        let store = MemoryDeviceSessionStore(
            StoredDeviceSession(pair: pair, source: .passkey, pendingNextRefreshToken: nil)
        )
        let controller = DeviceSessionController(store: store, enabled: true)

        let owner = await controller.activate(clerkID: "clerk-other")
        let token = try await controller.accessToken(expectedOwnerID: "server-native", forceRefresh: false)

        XCTAssertEqual(owner, "server-native")
        XCTAssertEqual(token, "mta_at_native")
        XCTAssertNil(store.value?.pendingRevocation)
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
            store: store,
            enabled: true
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
        let controller = DeviceSessionController(store: store, enabled: true)

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
            store: store,
            enabled: true
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
        let controller = DeviceSessionController(store: store, enabled: true)

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
            ),
            enabled: true
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

    @MainActor
    func testClerkFallbackRequiresTheSameStableOwner() {
        let pair = DeviceSessionPair(
            sessionID: "session-a", userID: "server-a", accessToken: "mta_at_valid",
            accessExpiresAt: .distantFuture, refreshToken: "mta_rt_valid",
            inactiveExpiresAt: .distantFuture
        )
        let controller = DeviceSessionController(
            store: MemoryDeviceSessionStore(
                StoredDeviceSession(
                    pair: pair,
                    source: .clerk,
                    verifiedClerkID: "clerk-a"
                )
            ),
            enabled: true
        )

        XCTAssertTrue(controller.canFallbackToClerk(clerkID: "clerk-a", expectedOwnerID: nil))
        XCTAssertTrue(controller.canFallbackToClerk(clerkID: "clerk-a", expectedOwnerID: "server-a"))
        XCTAssertFalse(controller.canFallbackToClerk(clerkID: "clerk-b", expectedOwnerID: nil))
        XCTAssertFalse(controller.canFallbackToClerk(clerkID: "clerk-a", expectedOwnerID: "server-b"))
    }
}
