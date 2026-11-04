import Foundation
import Observation
import Security

/// Credentials issued by the Media Tools API after a verified first-party sign-in.
/// These are opaque server values, not JWTs to decode on the device.
struct DeviceSessionPair: Codable, Equatable {
    let sessionID: String
    let userID: String
    let accessToken: String
    let accessExpiresAt: Date
    let refreshToken: String
    let inactiveExpiresAt: Date

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case userID = "user_id"
        case accessToken = "access_token"
        case accessExpiresAt = "access_expires_at"
        case refreshToken = "refresh_token"
        case inactiveExpiresAt = "inactive_expires_at"
    }
}

enum DeviceSessionSource: String, Codable, Equatable {
    /// Written by build 13 and earlier for a session bootstrapped through the
    /// retired provider. Decoding it must keep working: this type is read with
    /// `try?`, so dropping the case would sign that person out. It is converted
    /// on load and never written again.
    case clerk
    case passkey
    case recoveryCode
}

struct StoredDeviceSession: Codable, Equatable {
    var pair: DeviceSessionPair
    var source: DeviceSessionSource
    /// Build 13 and earlier only. Converted into a local owner mapping on load.
    var verifiedClerkID: String?
    /// Written before refresh so a lost response can retry the same rotation.
    var pendingNextRefreshToken: String?
    /// A signed-out credential retained only to retry server revocation.
    var pendingRevocation: Bool?

    init(pair: DeviceSessionPair,
         source: DeviceSessionSource = .passkey,
         verifiedClerkID: String? = nil,
         pendingNextRefreshToken: String? = nil,
         pendingRevocation: Bool? = nil) {
        self.pair = pair
        self.source = source
        self.verifiedClerkID = verifiedClerkID
        self.pendingNextRefreshToken = pendingNextRefreshToken
        self.pendingRevocation = pendingRevocation
    }

    enum CodingKeys: String, CodingKey {
        case pair
        case source
        case verifiedClerkID
        case pendingNextRefreshToken
        case pendingRevocation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pair = try container.decode(DeviceSessionPair.self, forKey: .pair)
        verifiedClerkID = try container.decodeIfPresent(String.self, forKey: .verifiedClerkID)
        // A source this build does not recognize must not read as "no session".
        // The refresh token is what authenticates; the source is only a label.
        let rawSource = try container.decodeIfPresent(String.self, forKey: .source)
        source = rawSource.flatMap(DeviceSessionSource.init(rawValue:))
            ?? (verifiedClerkID == nil ? .passkey : .clerk)
        pendingNextRefreshToken = try container.decodeIfPresent(String.self, forKey: .pendingNextRefreshToken)
        pendingRevocation = try container.decodeIfPresent(Bool.self, forKey: .pendingRevocation)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pair, forKey: .pair)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(verifiedClerkID, forKey: .verifiedClerkID)
        try container.encodeIfPresent(pendingNextRefreshToken, forKey: .pendingNextRefreshToken)
        try container.encodeIfPresent(pendingRevocation, forKey: .pendingRevocation)
    }

    /// Whether this value still carries anything from the retired provider.
    var needsLegacyConversion: Bool {
        source == .clerk || verifiedClerkID != nil
    }
}

/// Build 13 saved this before asking the server for a first session. `nextRefreshToken`
/// is the session's first refresh credential, so if the response was lost, this is
/// the only copy of a session the server already created. Nothing writes a new one.
struct PendingDeviceSessionBootstrap: Codable, Equatable {
    let verifiedClerkID: String
    let nextRefreshToken: String
    /// Written before recovery refreshes, so a second lost response repeats the same
    /// rotation. Older builds ignore this key.
    var recoverySuccessorToken: String? = nil
}

enum PendingBootstrapLoadResult: Equatable {
    case found(PendingDeviceSessionBootstrap)
    case missing
    case unavailable
}

/// App-only Keychain item. The Share Extension never receives this credential;
/// it has its own capture-only key. See `ShareUploadCredential`.
/// A Keychain read has three real outcomes. "Unavailable" usually means the
/// iPhone has not been unlocked since restart. Treating it like "missing" would
/// sign a person out of a session that is still sitting safely in the Keychain.
enum DeviceSessionLoadResult: Equatable {
    case found(StoredDeviceSession)
    case missing
    case unavailable
}

@MainActor
protocol DeviceSessionStoring {
    func load() -> StoredDeviceSession?
    func loadResult() -> DeviceSessionLoadResult
    func save(_ value: StoredDeviceSession) throws
    func delete()
    func localOwnerID(for clerkID: String) -> String?
    func clerkID(forLocalOwnerID ownerID: String) -> String?
    func saveLocalOwnerID(_ ownerID: String, for clerkID: String)
    func removeLocalOwnerID(for clerkID: String)
    func loadPendingBootstrap() -> PendingBootstrapLoadResult
    func savePendingBootstrap(_ value: PendingDeviceSessionBootstrap) throws
    func deletePendingBootstrap()
}

extension DeviceSessionStoring {
    func loadResult() -> DeviceSessionLoadResult {
        load().map(DeviceSessionLoadResult.found) ?? .missing
    }

    func loadPendingBootstrap() -> PendingBootstrapLoadResult { .missing }
    func savePendingBootstrap(_ value: PendingDeviceSessionBootstrap) throws {}
    func deletePendingBootstrap() {}
}

struct DeviceSessionKeychainStore: DeviceSessionStoring {
    private let service = "com.shimizu-technology.media-tools.device-session"
    private let account: String
    /// Build 13's bootstrap journal, under this same service.
    private let pendingBootstrapAccount = "first-party-ios-bootstrap-v1"
    private let ownerMappingsKey = "verifiedLocalOwnerMappings.v1"

    init(account: String = "first-party-ios-v1") {
        self.account = account
    }

    // This metadata grants no API access. Keep it separate from credentials:
    // signing out must not disconnect recordings already migrated locally.
    private var ownerMappings: [String: String] {
        UserDefaults.standard.dictionary(forKey: ownerMappingsKey) as? [String: String] ?? [:]
    }

    func localOwnerID(for clerkID: String) -> String? { ownerMappings[clerkID] }

    func clerkID(forLocalOwnerID ownerID: String) -> String? {
        ownerMappings.first(where: { $0.value == ownerID })?.key
    }

    func saveLocalOwnerID(_ ownerID: String, for clerkID: String) {
        var mappings = ownerMappings
        mappings[clerkID] = ownerID
        UserDefaults.standard.set(mappings, forKey: ownerMappingsKey)
    }

    func removeLocalOwnerID(for clerkID: String) {
        var mappings = ownerMappings
        mappings.removeValue(forKey: clerkID)
        UserDefaults.standard.set(mappings, forKey: ownerMappingsKey)
    }

    func load() -> StoredDeviceSession? {
        if case .found(let session) = loadResult() { return session }
        return nil
    }

    func loadResult() -> DeviceSessionLoadResult {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        #if targetEnvironment(simulator)
        // An unsigned simulator build has no Keychain at all, so waiting for an
        // unlock would never end. Signed builds always have this entitlement.
        if status == errSecMissingEntitlement { return .missing }
        #endif
        guard status == errSecSuccess, let data = result as? Data else { return .unavailable }
        // Unreadable data will not improve on a retry, so it counts as missing.
        // The item is left in place rather than deleted.
        guard let session = try? JSONDecoder().decode(StoredDeviceSession.self, from: data) else {
            return .missing
        }
        return .found(session)
    }

    func save(_ value: StoredDeviceSession) throws {
        let data = try JSONEncoder().encode(value)
        let status = SecItemUpdate(baseQuery(account: account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainFailure(status: status) }
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainFailure(status: addStatus) }
    }

    func delete() {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        deletePendingBootstrap()
    }

    func loadPendingBootstrap() -> PendingBootstrapLoadResult {
        var query = baseQuery(account: pendingBootstrapAccount)
        query[kSecReturnData as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        #if targetEnvironment(simulator)
        if status == errSecMissingEntitlement { return .missing }
        #endif
        guard status == errSecSuccess, let data = result as? Data else { return .unavailable }
        guard let value = try? JSONDecoder().decode(PendingDeviceSessionBootstrap.self, from: data) else {
            return .missing
        }
        return .found(value)
    }

    func savePendingBootstrap(_ value: PendingDeviceSessionBootstrap) throws {
        let data = try JSONEncoder().encode(value)
        let status = SecItemUpdate(
            baseQuery(account: pendingBootstrapAccount) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
    }

    func deletePendingBootstrap() {
        SecItemDelete(baseQuery(account: pendingBootstrapAccount) as CFDictionary)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

protocol DeviceSessionTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: DeviceSessionTransport {}

/// Identities build 13 retired locally: a sign-out or deletion it could not finish
/// against the provider. A stored session under one of these must not reopen.
@MainActor
protocol RetiredLegacyIdentityStoring: AnyObject {
    func contains(_ clerkID: String) -> Bool
    func removeAll()
}

@MainActor
final class RetiredLegacyIdentityStore: RetiredLegacyIdentityStoring {
    static let shared = RetiredLegacyIdentityStore()

    private let defaults: UserDefaults
    private let key = "locallyDeletedClerkIdentityIDs.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func contains(_ clerkID: String) -> Bool {
        (defaults.stringArray(forKey: key) ?? []).contains(clerkID)
    }

    func removeAll() {
        defaults.removeObject(forKey: key)
    }
}

private struct KeychainFailure: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Could not secure this device session (\(status))." }
}

@MainActor
@Observable
final class DeviceSessionController {
    static let shared: DeviceSessionController = {
        #if DEBUG
        if let fixture = UITestDeviceSessionFixture.current {
            return DeviceSessionController(
                transport: fixture.transport,
                store: fixture.store
            )
        }
        #endif
        return DeviceSessionController()
    }()

    private let store: any DeviceSessionStoring
    private let transport: any DeviceSessionTransport
    private let baseURL: URL
    private let retiredLegacyIdentities: any RetiredLegacyIdentityStoring
    private var stored: StoredDeviceSession?
    private var refreshTask: Task<DeviceSessionPair, Error>?
    private var pendingBootstrapRecovery: Task<Void, Never>?
    private var generation = 0

    private(set) var activeUserID: String?
    private(set) var needsSignIn = false
    private(set) var sessionRevision = 0
    /// The Keychain could not answer, so "no session" is not actually known yet.
    private(set) var isSessionStoreUnavailable = false
    /// Build 13 may have left a session here that only the server can confirm, and
    /// the server could not be reached. Asking this person to sign in would be wrong.
    private(set) var isAwaitingSessionRecovery = false

    /// Called whenever this credential stops being usable, however that happened.
    /// The share extension's key must not outlive the session that minted it.
    @ObservationIgnored var onCredentialEnded: (() -> Void)?
    /// Runs while a session can still authenticate, just before it is revoked.
    /// Keys can only be revoked by a session, so this is the last chance to.
    @ObservationIgnored var beforeSessionRevocation: ((_ bearerToken: String, _ ownerID: String) async -> Void)?

    init(transport: any DeviceSessionTransport = URLSession.shared,
         baseURL: URL = URL(string: Configuration.apiBaseURL + "/api/v1")!,
         store: (any DeviceSessionStoring)? = nil,
         retiredLegacyIdentities: (any RetiredLegacyIdentityStoring)? = nil) {
        self.transport = transport
        self.baseURL = baseURL
        self.store = store ?? DeviceSessionKeychainStore()
        self.retiredLegacyIdentities = retiredLegacyIdentities ?? RetiredLegacyIdentityStore.shared
        applyStoreRead(self.store.loadResult())
    }

    /// Takes a stored session as the workspace owner without touching the
    /// network, so the app opens immediately. Background activation still
    /// refreshes it and closes the workspace if the server rejects it.
    private func applyStoreRead(_ result: DeviceSessionLoadResult) {
        switch result {
        case .found(let session):
            let current = convertedFromLegacySource(session)
            stored = current
            // Build 13 saved the session, then ended before removing its journal.
            // That token may have rotated since, and reusing one revokes the device.
            store.deletePendingBootstrap()
            isSessionStoreUnavailable = false
            if current.pendingRevocation != true {
                activeUserID = current.pair.userID
            }
        case .missing:
            stored = nil
            isSessionStoreUnavailable = false
        case .unavailable:
            stored = nil
            isSessionStoreUnavailable = true
        }
    }

    /// A session stored by build 13 through the retired provider keeps working
    /// after the update: its refresh token is an ordinary first-party credential.
    ///
    /// The provider identity moves to the local owner mapping, because recordings
    /// and consent saved under it are still keyed by that ID. `.passkey` is the
    /// value older builds understand, so a rollback still decodes this session.
    /// If the save fails the conversion runs again on the next read.
    private func convertedFromLegacySource(_ session: StoredDeviceSession) -> StoredDeviceSession {
        guard session.needsLegacyConversion else { return session }
        var converted = session
        if let clerkID = session.verifiedClerkID {
            store.saveLocalOwnerID(session.pair.userID, for: clerkID)
            // A sign-out or deletion build 13 had not finished stays finished.
            if retiredLegacyIdentities.contains(clerkID) {
                converted.pendingRevocation = true
            }
        }
        converted.source = .passkey
        converted.verifiedClerkID = nil
        if (try? store.save(converted)) != nil {
            retiredLegacyIdentities.removeAll()
        }
        return converted
    }

    /// Re-reads only after a failed read. Called on every foreground, because
    /// the iPhone may have been unlocked since the app launched in the background.
    func reloadStoredSessionIfUnavailable() {
        guard isSessionStoreUnavailable else { return }
        let result = store.loadResult()
        guard result != .unavailable else { return }
        applyStoreRead(result)
        sessionRevision += 1
    }

    /// Local recordings and consent that may still be keyed by the provider ID
    /// this account used before. Moving them is repeatable and safe: the mapping
    /// was verified by the server for exactly this account.
    var verifiedMigration: (clerkID: String, userID: String)? {
        guard let stored, stored.pendingRevocation != true,
              let clerkID = store.clerkID(forLocalOwnerID: stored.pair.userID) else { return nil }
        return (clerkID, stored.pair.userID)
    }

    /// Saves a mapping from `GET /auth/me`, for a recording saved before this
    /// iPhone ever had a device session. Only the server can say the two match.
    func adoptServerVerifiedLegacyIdentity(_ clerkID: String, ownerID: String) {
        guard stored?.pair.userID == ownerID, stored?.pendingRevocation != true else { return }
        store.saveLocalOwnerID(ownerID, for: clerkID)
    }

    var storedUserID: String? { stored?.pair.userID }

    /// Lets the devices list mark this iPhone and keep it from being revoked there.
    var currentSessionID: String? { stored?.pair.sessionID }

    var hasNativeFirstPartySession: Bool {
        guard let stored else { return false }
        return stored.pendingRevocation != true
    }

    /// Called before exposing an account workspace.
    func activate() async -> String? {
        reloadStoredSessionIfUnavailable()
        // The session may still be in the locked Keychain. Nothing is known yet,
        // and the local recordings stay exactly where they are.
        if isSessionStoreUnavailable { return nil }
        if stored == nil {
            await recoverPendingBootstrap()
            if isSessionStoreUnavailable || isAwaitingSessionRecovery {
                activeUserID = nil
                return nil
            }
        }
        if let stored, stored.pendingRevocation == true {
            do {
                try await revokeAndClear()
            } catch {
                // A suspended credential is never used for the workspace.
                activeUserID = nil
                return nil
            }
        }
        guard !needsSignIn, let stored else {
            activeUserID = nil
            return nil
        }
        if stored.pair.accessExpiresAt <= Date().addingTimeInterval(60) {
            do {
                _ = try await refresh()
            } catch {
                // Preserve the local session and recordings during a network
                // outage. A later API request retries the same rotation.
                if needsSignIn {
                    activeUserID = nil
                    return nil
                }
            }
        }
        activeUserID = self.stored?.pair.userID
        return activeUserID
    }

    /// Returns nil when this client has no first-party credential.
    func accessToken(expectedOwnerID: String?, forceRefresh: Bool,
                     forRevocation: Bool = false) async throws -> String? {
        guard let stored else { return nil }
        if stored.pendingRevocation == true && !forRevocation { return nil }
        guard expectedOwnerID == nil || expectedOwnerID == stored.pair.userID else {
            throw APIError.authenticationRequired(message: "The signed-in account changed. Switch back to continue this upload.")
        }
        if forceRefresh || stored.pair.accessExpiresAt <= Date().addingTimeInterval(60) {
            return try await refresh().accessToken
        }
        return stored.pair.accessToken
    }

    func clear() {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        stored = nil
        activeUserID = nil
        needsSignIn = false
        isAwaitingSessionRecovery = false
        store.delete()
        sessionRevision += 1
        onCredentialEnded?()
    }

    func prepareForNewNativeSession() async throws {
        guard stored != nil else { return }
        guard stored?.pendingRevocation != true else {
            throw APIError.authenticationRequired(message: "Finish signing out before switching accounts.")
        }
        try await revokeAndClear()
        guard stored == nil else {
            throw APIError.authenticationRequired(message: "Sign out before switching accounts.")
        }
    }

    func replaceSession(pair: DeviceSessionPair,
                        source: DeviceSessionSource) async throws {
        if let stored, stored.pair.sessionID != pair.sessionID {
            guard stored.pendingRevocation != true else {
                throw APIError.authenticationRequired(message: "Finish signing out before switching accounts.")
            }
            try await revokeAndClear()
        }
        try saveSession(pair: pair, source: source)
    }

    func saveSession(pair: DeviceSessionPair,
                     source: DeviceSessionSource) throws {
        guard stored == nil || stored?.pair.sessionID == pair.sessionID else {
            throw APIError.authenticationRequired(message: "Sign out before switching accounts.")
        }
        guard stored?.pendingRevocation != true else {
            throw APIError.authenticationRequired(message: "Finish signing out before switching accounts.")
        }
        guard !pair.userID.isEmpty, !pair.sessionID.isEmpty,
              !pair.accessToken.isEmpty, !pair.refreshToken.isEmpty else {
            throw APIError.invalidResponse
        }
        guard source != .clerk else { throw APIError.invalidResponse }
        let value = StoredDeviceSession(
            pair: pair,
            source: source,
            verifiedClerkID: nil,
            pendingNextRefreshToken: nil,
            pendingRevocation: nil
        )
        try store.save(value)
        store.deletePendingBootstrap()
        isAwaitingSessionRecovery = false
        stored = value
        activeUserID = pair.userID
        needsSignIn = false
        generation += 1
        sessionRevision += 1
        refreshTask?.cancel()
        refreshTask = nil
    }

    func removeLocalOwnerMappings(ownerID: String) {
        while let clerkID = store.clerkID(forLocalOwnerID: ownerID) {
            store.removeLocalOwnerID(for: clerkID)
        }
    }

    func revokeAndClear() async throws {
        guard let sessionID = stored?.pair.sessionID else {
            clear()
            return
        }
        let startingGeneration = generation
        do {
            try await revoke(sessionID: sessionID, forceRefresh: false)
        } catch APIError.httpError(401, _, _) {
            do {
                try await revoke(sessionID: sessionID, forceRefresh: true)
            } catch APIError.authenticationRequired where needsSignIn {
                // Refresh confirmed that the server session is invalid.
            }
        } catch APIError.httpError(404, _, _) {
            do {
                _ = try await refresh()
            } catch APIError.authenticationRequired where needsSignIn {
                // A lost DELETE response can leave a 404; refresh confirms
                // whether the session was actually revoked.
                guard generation == startingGeneration else { throw CancellationError() }
                clear()
                return
            }
            try await revoke(sessionID: sessionID, forceRefresh: false)
        } catch APIError.authenticationRequired where needsSignIn {
            // Refresh confirmed that the server session is invalid.
        }
        guard generation == startingGeneration else { throw CancellationError() }
        clear()
    }

    /// Complete local sign-out even when server revocation is unavailable.
    /// The suspended credential remains device-only and can only be used to
    /// retry revocation; it cannot authenticate API workspace requests.
    func revokeOrSuspend() async throws {
        let sessionID = stored?.pair.sessionID
        do {
            try await revokeAndClear()
        } catch {
            guard let value = stored, value.pair.sessionID == sessionID else { throw error }
            try suspendForRevocation(value)
        }
    }

    private func suspendForRevocation(_ value: StoredDeviceSession) throws {
        var suspended = value
        suspended.pendingRevocation = true
        try store.save(suspended)
        stored = suspended
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        activeUserID = nil
        needsSignIn = false
        onCredentialEnded?()
    }

    private func revoke(sessionID: String, forceRefresh: Bool) async throws {
        guard let token = try await accessToken(expectedOwnerID: stored?.pair.userID,
                                                forceRefresh: forceRefresh,
                                                forRevocation: true) else {
            throw APIError.authenticationRequired(message: "Sign in to finish signing out.")
        }
        if let ownerID = stored?.pair.userID {
            await beforeSessionRevocation?(token, ownerID)
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/sessions/\(sessionID)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard http.statusCode == 204 else {
            let errorBody = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw APIError.httpError(statusCode: http.statusCode, code: errorBody?.error,
                                     message: errorBody?.message ?? "Could not revoke this device")
        }
    }

    /// Not tied to the caller, because cancelling the request would leave a rotation
    /// unconfirmed for no reason. Concurrent activations share one recovery.
    private func recoverPendingBootstrap() async {
        if let pendingBootstrapRecovery {
            await pendingBootstrapRecovery.value
            return
        }
        let task = Task { await recoverPendingBootstrapOnce() }
        pendingBootstrapRecovery = task
        await task.value
        pendingBootstrapRecovery = nil
    }

    /// The server may have committed build 13's bootstrap and lost the response. The
    /// journal's token is then this session's live refresh credential, and refreshing
    /// is the only way to learn its account. A token the server never saw gets a 401,
    /// which is the one answer that means there is no session to recover.
    private func recoverPendingBootstrapOnce() async {
        guard stored == nil else { return }
        var journal: PendingDeviceSessionBootstrap
        switch store.loadPendingBootstrap() {
        case .missing:
            isAwaitingSessionRecovery = false
            return
        case .unavailable:
            isSessionStoreUnavailable = true
            return
        case .found(let value):
            journal = value
        }
        // A sign-out or deletion build 13 had not finished stays finished: the session
        // is recovered only so that it can be revoked, and never opens a workspace.
        let signOutIntended = retiredLegacyIdentities.contains(journal.verifiedClerkID)
        isAwaitingSessionRecovery = !signOutIntended
        let startingGeneration = generation
        do {
            if journal.recoverySuccessorToken == nil {
                journal.recoverySuccessorToken = try Self.randomRefreshToken()
                try store.savePendingBootstrap(journal)
            }
            guard let next = journal.recoverySuccessorToken else { throw APIError.invalidResponse }
            var request = URLRequest(url: baseURL.appendingPathComponent("auth/session/refresh"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "refresh_token": journal.nextRefreshToken,
                "next_refresh_token": next,
            ])
            let pair = try await sendPairRequest(request)
            guard startingGeneration == generation, stored == nil else { return }
            guard !pair.userID.isEmpty, !pair.sessionID.isEmpty, !pair.accessToken.isEmpty,
                  pair.refreshToken == next else { throw APIError.invalidResponse }
            let value = StoredDeviceSession(
                pair: pair,
                source: .passkey,
                pendingRevocation: signOutIntended ? true : nil
            )
            // Kept until the session is saved: a failed save repeats this same rotation.
            try store.save(value)
            store.saveLocalOwnerID(pair.userID, for: journal.verifiedClerkID)
            store.deletePendingBootstrap()
            stored = value
            isAwaitingSessionRecovery = false
            if signOutIntended {
                retiredLegacyIdentities.removeAll()
            } else {
                activeUserID = pair.userID
            }
        } catch APIError.httpError(let status, _, _) where [400, 401, 409].contains(status) {
            // Unknown, revoked, or already rotated elsewhere. No retry can recover it.
            guard startingGeneration == generation else { return }
            store.deletePendingBootstrap()
            isAwaitingSessionRecovery = false
            if signOutIntended { retiredLegacyIdentities.removeAll() }
        } catch {
            // Offline or a server fault says nothing about the session. The journal stays.
        }
    }

    private func refresh() async throws -> DeviceSessionPair {
        if let refreshTask { return try await refreshTask.value }
        let taskGeneration = generation
        let task = Task { try await refreshOnce() }
        refreshTask = task
        defer {
            if generation == taskGeneration { refreshTask = nil }
        }
        return try await task.value
    }

    private func refreshOnce() async throws -> DeviceSessionPair {
        let startingGeneration = generation
        guard var value = stored else {
            throw APIError.authenticationRequired(message: "Sign in to continue.")
        }
        if value.pendingNextRefreshToken == nil {
            value.pendingNextRefreshToken = try Self.randomRefreshToken()
            try store.save(value)
            stored = value
        }
        guard let next = value.pendingNextRefreshToken else { throw APIError.invalidResponse }
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/session/refresh"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "refresh_token": value.pair.refreshToken,
            "next_refresh_token": next,
        ])
        let pair: DeviceSessionPair
        do {
            pair = try await sendPairRequest(request)
        } catch APIError.httpError(401, _, _) {
            guard startingGeneration == generation else { throw CancellationError() }
            needsSignIn = true
            activeUserID = nil
            onCredentialEnded?()
            throw APIError.authenticationRequired(message: "Sign in to continue.")
        }
        guard startingGeneration == generation,
              stored?.pair.sessionID == value.pair.sessionID,
              stored?.pendingNextRefreshToken == next,
              !Task.isCancelled else { throw CancellationError() }
        guard pair.userID == value.pair.userID,
              pair.sessionID == value.pair.sessionID,
              pair.refreshToken == next else { throw APIError.invalidResponse }
        value.pair = pair
        value.pendingNextRefreshToken = nil
        try store.save(value)
        stored = value
        needsSignIn = false
        return pair
    }

    private func sendPairRequest(_ request: URLRequest) async throws -> DeviceSessionPair {
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let errorBody = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw APIError.httpError(statusCode: http.statusCode, code: errorBody?.error,
                                     message: errorBody?.message ?? "Device session unavailable")
        }
        let decoder = APIClient.makeDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        return try decoder.decode(DeviceSessionPair.self, from: data)
    }

    static func randomRefreshToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        return "mta_rt_" + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
