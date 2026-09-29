import XCTest
@testable import MediaTools

@MainActor
private final class MemoryDeviceSessionStore: DeviceSessionStoring {
    var value: StoredDeviceSession?
    init(_ value: StoredDeviceSession?) { self.value = value }
    func load() -> StoredDeviceSession? { value }
    func save(_ value: StoredDeviceSession) throws { self.value = value }
    func delete() { value = nil }
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
}
