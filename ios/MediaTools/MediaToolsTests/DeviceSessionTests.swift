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
}
