#if DEBUG
import Foundation

/// A deterministic signed-in session for UI tests, so they can exercise the real
/// launch path through `ContentView`. Debug builds only; never reaches a server.
///
/// `-ui-test-signed-in` gives a valid session. Adding `-ui-test-expired-session`
/// forces the startup refresh, and `-ui-test-stalled-network` makes it hang, which
/// proves the workspace opens without waiting for the network.
///
/// `-ui-test-pending-bootstrap` instead gives only the journal build 13 leaves when
/// a response is lost. The first refresh fails, as if offline, and the next succeeds.
@MainActor
struct UITestDeviceSessionFixture {
    static let ownerID = "ui-test-owner"

    let store: any DeviceSessionStoring
    let transport: any DeviceSessionTransport

    static var current: UITestDeviceSessionFixture? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-ui-test-pending-bootstrap") {
            return UITestDeviceSessionFixture(
                store: UITestDeviceSessionStore(
                    stored: nil,
                    pendingBootstrap: PendingDeviceSessionBootstrap(
                        verifiedClerkID: "user_uiTestLegacy",
                        nextRefreshToken: "mta_rt_ui-test-journal"
                    )
                ),
                transport: UITestPendingBootstrapTransport()
            )
        }
        guard arguments.contains("-ui-test-signed-in") else { return nil }
        let expiry = arguments.contains("-ui-test-expired-session")
            ? Date().addingTimeInterval(-60)
            : Date().addingTimeInterval(24 * 60 * 60)
        let pair = DeviceSessionPair(
            sessionID: "ui-test-session",
            userID: ownerID,
            accessToken: "ui-test-access",
            accessExpiresAt: expiry,
            refreshToken: "ui-test-refresh",
            inactiveExpiresAt: Date().addingTimeInterval(30 * 24 * 60 * 60)
        )
        return UITestDeviceSessionFixture(
            store: UITestDeviceSessionStore(
                stored: StoredDeviceSession(pair: pair, source: .passkey)
            ),
            transport: UITestDeviceSessionTransport(
                stalls: arguments.contains("-ui-test-stalled-network")
            )
        )
    }
}

@MainActor
private final class UITestDeviceSessionStore: DeviceSessionStoring {
    private var stored: StoredDeviceSession?
    private var pendingBootstrap: PendingDeviceSessionBootstrap?
    private var localOwners: [String: String] = [:]

    init(stored: StoredDeviceSession?, pendingBootstrap: PendingDeviceSessionBootstrap? = nil) {
        self.stored = stored
        self.pendingBootstrap = pendingBootstrap
    }

    func load() -> StoredDeviceSession? { stored }
    func save(_ value: StoredDeviceSession) throws { stored = value }
    func delete() {
        stored = nil
        pendingBootstrap = nil
    }
    func loadPendingBootstrap() -> PendingBootstrapLoadResult {
        pendingBootstrap.map(PendingBootstrapLoadResult.found) ?? .missing
    }
    func savePendingBootstrap(_ value: PendingDeviceSessionBootstrap) throws { pendingBootstrap = value }
    func deletePendingBootstrap() { pendingBootstrap = nil }
    func localOwnerID(for clerkID: String) -> String? { localOwners[clerkID] }
    func clerkID(forLocalOwnerID ownerID: String) -> String? {
        localOwners.first { $0.value == ownerID }?.key
    }
    func saveLocalOwnerID(_ ownerID: String, for clerkID: String) { localOwners[clerkID] = ownerID }
    func removeLocalOwnerID(for clerkID: String) { localOwners[clerkID] = nil }
}

private struct UITestDeviceSessionTransport: DeviceSessionTransport {
    let stalls: Bool

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if stalls {
            try await Task.sleep(for: .seconds(3_600))
        }
        throw URLError(.notConnectedToInternet)
    }
}

private actor UITestPendingBootstrapTransport: DeviceSessionTransport {
    private var attempts = 0

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        attempts += 1
        guard attempts > 1 else {
            // Slow enough that launch finishes first, as a real timeout would.
            try await Task.sleep(for: .seconds(1))
            throw URLError(.notConnectedToInternet)
        }
        let sent = request.httpBody
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        let body = try JSONSerialization.data(withJSONObject: [
            "session_id": "ui-test-session",
            "user_id": UITestDeviceSessionFixture.ownerID,
            "access_token": "ui-test-access",
            "access_expires_at": "2099-01-01T00:00:00Z",
            "refresh_token": sent?["next_refresh_token"] ?? "",
            "inactive_expires_at": "2099-01-01T00:00:00Z",
        ])
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// Puts a share in the real inbox before launch finishes, as the extension would.
enum UITestShareFixture {
    static let linkTitle = "Fixture shared video"

    static func prepare(arguments: [String]) {
        guard let inbox = try? ShareInboxStore() else { return }
        if arguments.contains("-ui-test-reset-recordings") {
            for item in (try? inbox.pendingItems()) ?? [] {
                try? inbox.remove(item)
            }
        }
        if arguments.contains("-ui-test-staged-link"),
           let url = URL(string: "https://youtu.be/ui-test") {
            _ = try? inbox.stageLink(url, title: linkTitle)
        }
        // Work a retired-provider account left on this iPhone. See `/auth/me` below.
        if arguments.contains("-ui-test-legacy-owned-share"),
           let url = URL(string: "https://youtu.be/ui-test-legacy"),
           var item = try? inbox.stageLink(url, title: linkTitle) {
            item.ownerID = UITestAPIProtocol.legacyProviderID
            try? inbox.update(item)
        }
    }
}

/// Stands in for the API while `-ui-test-signed-in` is active. It reflects what
/// the simulated upload accepted, so a test can watch the Library update itself.
final class UITestAPIProtocol: URLProtocol {
    static let audioID = "ui-test-audio"
    static let legacyProviderID = "user_uiTestLegacy"
    private static let lock = NSLock()
    private nonisolated(unsafe) static var acceptedAudioTitle: String?
    private nonisolated(unsafe) static var accountProfileRequests = 0

    /// The first request fails, as if offline, so a test can watch the app recover.
    private static func nextAccountProfileRequest() -> Int {
        lock.lock()
        defer { lock.unlock() }
        accountProfileRequests += 1
        return accountProfileRequests
    }

    static func acceptAudio(title: String) {
        lock.lock()
        defer { lock.unlock() }
        acceptedAudioTitle = title
    }

    private static var currentAudioTitle: String? {
        lock.lock()
        defer { lock.unlock() }
        return acceptedAudioTitle
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return fail() }
        let path = url.path
        if path.hasSuffix("/auth/signup") || path.hasSuffix("/auth/password/forgot") {
            respond(["message": "If this request is eligible, an email will arrive shortly"])
        } else if path.hasSuffix("/auth/me") {
            guard Self.nextAccountProfileRequest() > 1 else { return fail() }
            respond([
                "id": UITestDeviceSessionFixture.ownerID,
                "email": "owner@example.com",
                "name": "Owner",
                "clerk_id": Self.legacyProviderID,
            ])
        } else if path.hasSuffix("/library/items") {
            respond(libraryList())
        } else if path.hasSuffix("/preferences") {
            respond(["favorite": false, "archived": false, "tags": []])
        } else if path.hasSuffix("/segments") {
            respond([])
        } else if path.hasSuffix("/audio/transcriptions/\(Self.audioID)") {
            respond([
                "id": Self.audioID,
                "title": Self.currentAudioTitle ?? "UI test recording",
                "status": "completed",
                "transcript_text": "Transcript from the UI test fixture.",
                "word_count": 6,
            ])
        } else if path.hasSuffix("/collections") {
            respond([
                ["id": "ui-test-collection", "name": "Fixture collection", "item_count": 1],
                ["id": "ui-test-broken-collection", "name": "Unreachable collection", "item_count": 0],
            ])
        } else if path.hasSuffix("/collections/ui-test-collection") {
            respond([
                "id": "ui-test-collection",
                "name": "Fixture collection",
                "items": [[
                    "id": "ui-test-collection-item",
                    "item_type": "audio",
                    "item_id": Self.audioID,
                    "item_title": "UI test recording",
                    "item_status": "completed",
                ]],
            ])
        } else if path.hasSuffix("/transcripts") {
            respond(transcript(status: "pending"))
        } else if path.hasSuffix("/transcripts/ui-test-transcript") {
            respond(transcript(status: "failed"))
        } else if path.hasSuffix("/chat"), request.httpMethod == "GET" {
            respond(["messages": []])
        } else {
            fail()
        }
    }

    private func transcript(status: String) -> [String: Any] {
        [
            "id": "ui-test-transcript",
            "title": "Fixture video",
            "status": status,
            "error_message": "The provider could not read this video.",
        ]
    }

    private func libraryList() -> [String: Any] {
        var items: [[String: Any]] = []
        if let title = Self.currentAudioTitle {
            items.append([
                "id": Self.audioID,
                "item_type": "audio",
                "title": title,
                "subtitle": "",
                "status": "completed",
                "word_count": 6,
                "duration": 1,
                "page_count": 0,
                "summary_status": "",
                "favorite": false,
                "archived": false,
                "tags": [],
                "created_at": "2026-11-04T00:00:00Z",
            ])
        }
        return [
            "data": items,
            "page": 1,
            "per_page": 20,
            "total_items": items.count,
            "total_pages": items.isEmpty ? 0 : 1,
        ]
    }

    private func respond(_ body: Any) {
        guard let url = request.url,
              let data = try? JSONSerialization.data(withJSONObject: body),
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
              )
        else { return fail() }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func fail() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
}
#endif
