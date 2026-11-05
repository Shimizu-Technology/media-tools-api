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
            guard Self.isRichContent || Self.nextAccountProfileRequest() > 1 else { return fail() }
            respond([
                "id": UITestDeviceSessionFixture.ownerID,
                "email": "owner@example.com",
                "name": "Owner",
                "clerk_id": Self.legacyProviderID,
            ])
        } else if Self.isRichContent, path.hasSuffix("/auth/usage") {
            respond([
                "month": "2026-11-01T00:00:00Z",
                "transcription_seconds": 2_160,
                "transcription_limit_seconds": 18_000,
                "ai_requests": 48,
                "ai_request_limit": 500,
                "exempt": false,
            ])
        } else if Self.isRichContent, path.hasSuffix("/auth/passkeys") {
            respond(["count": 1])
        } else if Self.isRichContent, path.hasSuffix("/auth/recovery") {
            respond(["remaining": 7])
        } else if Self.isRichContent, path.hasSuffix("/auth/password") {
            respond(["configured": true])
        } else if Self.isRichContent, path.hasSuffix("/health") {
            respond(["status": "ok", "version": "test", "database": "ok", "workers": 2, "password_auth_enabled": true])
        } else if path.hasSuffix("/library/items") {
            respond(libraryList(url: url))
        } else if path.hasSuffix("/preferences") {
            respond(["favorite": false, "archived": false, "tags": []])
        } else if path.hasSuffix("/segments") {
            respond(Self.isRichContent ? Self.richSegments : [])
        } else if Self.isRichContent, path.hasSuffix("/audio/transcriptions/\(Self.audioID)") {
            respond(Self.richAudio)
        } else if Self.isRichContent, path.hasSuffix("/audio/transcriptions/\(Self.audioID)/audio") {
            // Nothing plays by default, but the player reaches its loaded state for layout
            // review. `-ui-test-playable-audio` serves real silence, for following along.
            respond(["url": Self.playableAudioURL?.absoluteString ?? "https://example.invalid/fixture.m4a"])
        } else if path.hasSuffix("/audio/transcriptions/\(Self.audioID)") {
            respond([
                "id": Self.audioID,
                "title": Self.currentAudioTitle ?? "UI test recording",
                "status": "completed",
                "transcript_text": "Transcript from the UI test fixture.",
                "word_count": 6,
            ])
        } else if Self.isRichContent, path.hasSuffix("/collections") {
            respond(Self.richCollections)
        } else if Self.isRichContent, path.contains("/collections/rich-") {
            respond(Self.richCollection(id: url.lastPathComponent))
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

    // MARK: - Realistic content

    /// `-ui-test-rich-content` fills the Library and one item with believable lengths,
    /// for design review and the tests that need a summary and timestamps to act on.
    private static var isRichContent: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-test-rich-content")
    }

    private static func richLibraryItem(
        id: String,
        type: String = "audio",
        title: String,
        subtitle: String = "",
        status: String = "completed",
        duration: Double = 0,
        pageCount: Int = 0,
        hoursAgo: Double,
        favorite: Bool = false,
        archived: Bool = false,
        excerpt: String? = nil,
        hasWaveform: Bool = true,
        peakScale: Double = 1,
        collection: [String: String]? = nil
    ) -> [String: Any] {
        let created = Date().addingTimeInterval(-hoursAgo * 3_600)
        var item: [String: Any] = [
            "id": id,
            "item_type": type,
            "title": title,
            "subtitle": subtitle,
            "status": status,
            "word_count": Int(duration * 2),
            "duration": duration,
            "page_count": pageCount,
            "summary_status": "",
            "favorite": favorite,
            "archived": archived,
            "tags": [],
            "created_at": ISO8601DateFormatter().string(from: created),
            "collections": collection.map { [$0] } ?? [],
        ]
        if let excerpt { item["excerpt"] = excerpt }
        if type == "audio", hasWaveform, status == "completed" {
            item["waveform"] = fixturePeaks(count: 32, seed: id.utf8.reduce(0) { $0 + Double($1) }, scale: peakScale)
        }
        return item
    }

    /// A believable speech shape for design review. Debug fixtures only: real rows use
    /// the server's peaks, and nothing in a release build can draw these.
    private static func fixturePeaks(count: Int, seed: Double, scale: Double = 1) -> [Int] {
        (0..<count).map { index in
            let position = Double(index)
            let shape = abs(sin(seed * 1.7 + position * 0.9) * cos(seed + position * 0.37))
            return Int((12 + shape * 88) * scale)
        }
    }

    private static let babyCollection = ["id": "rich-baby", "name": "Baby", "color": "coral"]
    private static let workCollection = ["id": "rich-work", "name": "Work", "color": "teal"]
    private static let ideasCollection = ["id": "rich-ideas", "name": "Ideas", "color": "violet"]
    private static let callsCollection = ["id": "rich-calls", "name": "Calls", "color": "amber"]

    private static var richCollections: [[String: Any]] {
        [
            ["id": "rich-baby", "name": "Baby", "color": "coral", "item_count": 12],
            ["id": "rich-work", "name": "Work", "color": "teal", "item_count": 48],
            ["id": "rich-ideas", "name": "Ideas", "color": "violet", "item_count": 31],
            ["id": "rich-calls", "name": "Calls", "color": "amber", "item_count": 27],
            // No color yet, as before the server deploys: falls back to coral.
            ["id": "rich-long", "name": "Everything from the second quarter planning offsite in Hagåtña", "item_count": 1],
        ]
    }

    private static func richCollection(id: String) -> [String: Any] {
        let collection = richCollections.first { $0["id"] as? String == id } ?? [:]
        let members = richLibraryItems.filter { item in
            (item["collections"] as? [[String: String]])?.first?["id"] == id
        }
        var result = collection
        result["items"] = members.map { item in
            [
                "id": "member-\(item["id"] as? String ?? "")",
                "item_type": item["item_type"] as? String ?? "audio",
                "item_id": item["id"] as? String ?? "",
                "item_title": item["title"] as? String ?? "",
                "item_status": item["status"] as? String ?? "completed",
            ]
        }
        return result
    }

    private static var richLibraryItems: [[String: Any]] {
        [
            richLibraryItem(
                id: audioID, title: "Monday planning call", duration: 2_530, hoursAgo: 0.2, favorite: true,
                excerpt: "Launch moves to the 18th so QA can run a full week. Split QA between two people.",
                collection: workCollection
            ),
            richLibraryItem(id: "rich-2", title: "Parking lot idea", status: "processing", duration: 108, hoursAgo: 0.5),
            richLibraryItem(
                id: "rich-hafa", title: "Hafa Baby updates", duration: 516, hoursAgo: 14,
                excerpt: "What changed this week, what is still open, and what to test before the next round.",
                collection: babyCollection
            ),
            richLibraryItem(
                id: "rich-3",
                title: "Call with the bank about the account and the second signer they need before Friday",
                status: "failed",
                duration: 720,
                hoursAgo: 26
            ),
            richLibraryItem(id: "rich-4", title: "Grocery and pharmacy run", duration: 31, hoursAgo: 28),
            richLibraryItem(
                id: "rich-link", type: "youtube", title: "How to read a contract", subtitle: "YouTube",
                duration: 842, hoursAgo: 50,
                excerpt: "The clauses to read first, and the ones people usually skip.",
                collection: ideasCollection
            ),
            richLibraryItem(
                id: "rich-pdf", type: "pdf", title: "Lease agreement.pdf", pageCount: 18, hoursAgo: 60,
                excerpt: "Term, renewal dates and who pays for repairs.",
                collection: workCollection
            ),
            richLibraryItem(
                id: "rich-5", title: "Sunday sermon notes", subtitle: "Weekly teaching series",
                duration: 1_388, hoursAgo: 72,
                excerpt: "Three points on patience, with the reading for next week and a note about the youth group retreat that the pastor asked everyone to pray over before it leaves on Friday morning.",
                collection: callsCollection
            ),
            richLibraryItem(id: "rich-6", title: "Dentist follow-up", duration: 252, hoursAgo: 96, peakScale: 0.06),
            richLibraryItem(
                id: "rich-7", title: "Budget review with Aleksandra Wiśniewska-Kowalczyk and bartholomew.fitzgerald@northwind-industries-holdings.example.com",
                duration: 45_296, hoursAgo: 120,
                excerpt: "Eleven hours across two sessions.",
                collection: ["id": "rich-long", "name": "Everything from the second quarter planning offsite in Hagåtña"]
            ),
            richLibraryItem(id: "rich-8", title: "ハファ・アダイ 会議のメモ", duration: 600, hoursAgo: 150, favorite: true, hasWaveform: false),
            richLibraryItem(id: "rich-old-failure", title: "An old failure that stays in the Library", status: "failed", duration: 60, hoursAgo: 240),
            richLibraryItem(id: "rich-archived", title: "Archived hallway recording", duration: 90, hoursAgo: 300, archived: true),
        ]
    }

    /// Real silence, so a real player advances and the transcript can follow it.
    private static let playableAudioURL: URL? = {
        guard ProcessInfo.processInfo.arguments.contains("-ui-test-playable-audio") else { return nil }
        let sampleRate = 8_000
        let seconds = 180
        let dataSize = UInt32(sampleRate * seconds * 2)
        func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var wav = Data("RIFF".utf8) + le32(36 + dataSize) + Data("WAVEfmt ".utf8) + le32(16)
        wav += le16(1) + le16(1) + le32(UInt32(sampleRate)) + le32(UInt32(sampleRate * 2)) + le16(2) + le16(16)
        wav += Data("data".utf8) + le32(dataSize) + Data(count: Int(dataSize))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ui-test-silence.wav")
        guard (try? wav.write(to: url)) != nil else { return nil }
        return url
    }()

    private static let richTranscript = """
        Okay so the main thing I wanted to talk through is the date. I don’t think the eleventh gives us enough room for the retry work.

        Agreed. If we push a week we can actually test the failure path properly instead of hoping it works on the day.

        Eighteenth then. Let’s write that down. And for QA I’ll take the phone side and the share extension since that’s where I’m living anyway.

        That works. I’ll take the web upload and the agent endpoints. We should also decide whether the pricing page ships with this or after.

        After. It’s not worth holding anything for, and I’d rather not rush the copy. Send me the timeline when you have it and I’ll book the build for Friday.
        """

    private static var richAudio: [String: Any] {
        [
            "id": audioID,
            "title": "Monday planning call",
            "status": "completed",
            "transcript_text": richTranscript,
            "formatted_transcript_text": richTranscript,
            "formatting_status": "completed",
            "content_type": "meeting",
            "duration": 2_530,
            "word_count": 6_120,
            "created_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-720)),
            "waveform": fixturePeaks(count: 200, seed: 4),
            "summary_status": "completed",
            "summary_text": "Planning call about the launch. The date moves from the 11th to the 18th so QA can run a full week on the audio retry path. We split QA: I take iOS and the share extension, the other side takes the web upload and the agent endpoints.",
            "key_points": [
                "Launch moves to the 18th.",
                "QA split by platform, not by feature.",
                "Pricing page waits until after launch.",
            ],
            "action_items": [
                "Send the revised timeline by Wednesday.",
                "Book the TestFlight build for Friday.",
            ],
        ]
    }

    private static var richSegments: [[String: Any]] {
        let lines = richTranscript.components(separatedBy: "\n\n")
        let segmentLength = playableAudioURL == nil ? 42_000 : 4_000
        // Enough to scroll the player well out of view.
        return (0..<24).map { index in
            [
                "id": "segment-\(index)",
                "item_type": "audio",
                "item_id": audioID,
                "ordinal": index,
                "start_ms": index * segmentLength,
                "end_ms": (index + 1) * segmentLength,
                "text": lines[index % lines.count],
            ]
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

    /// Applies the query the way the server does, so chips and Home's short lists can
    /// be exercised for real.
    private func libraryList(url: URL) -> [String: Any] {
        var items: [[String: Any]] = Self.isRichContent ? Self.richLibraryItems : []
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
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value: (String) -> String? = { name in query.first { $0.name == name }?.value }
        let archivedOnly = value("archive") == "only"
        items = items.filter { (($0["archived"] as? Bool) ?? false) == archivedOnly }
        if let type = value("type") {
            items = items.filter { $0["item_type"] as? String == type }
        }
        if let status = value("status") {
            let statuses = status == "active" ? ["pending", "processing"] : [status]
            items = items.filter { statuses.contains($0["status"] as? String ?? "") }
        }
        if value("favorite") == "true" {
            items = items.filter { ($0["favorite"] as? Bool) == true }
        }
        if let search = value("search")?.lowercased() {
            items = items.filter { ($0["title"] as? String ?? "").lowercased().contains(search) }
        }
        if value("sort_dir") == "asc" {
            items.reverse()
        }
        let total = items.count
        let perPage = value("per_page").flatMap(Int.init) ?? 20
        return [
            "data": Array(items.prefix(perPage)),
            "page": 1,
            "per_page": perPage,
            "total_items": total,
            "total_pages": total == 0 ? 0 : 1,
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
