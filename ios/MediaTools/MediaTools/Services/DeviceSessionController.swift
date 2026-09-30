import Foundation
import Observation
import Security
import ClerkKit

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
    case clerk
    case passkey
    case recoveryCode
}

struct StoredDeviceSession: Codable, Equatable {
    var pair: DeviceSessionPair
    var source: DeviceSessionSource
    var verifiedClerkID: String?
    /// Written before refresh so a lost response can retry the same rotation.
    var pendingNextRefreshToken: String?
    /// A signed-out credential retained only to retry server revocation.
    var pendingRevocation: Bool?

    init(pair: DeviceSessionPair,
         source: DeviceSessionSource = .clerk,
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
        source = try container.decodeIfPresent(DeviceSessionSource.self, forKey: .source)
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

    var isClerkBacked: Bool {
        source == .clerk && verifiedClerkID != nil
    }

    func belongs(to clerkID: String) -> Bool {
        source == .clerk && verifiedClerkID == clerkID
    }
}

struct PendingDeviceSessionBootstrap: Codable, Equatable {
    let verifiedClerkID: String
    let nextRefreshToken: String
}

/// App-only Keychain item. The future Share Extension must not receive this
/// credential; its signed-out capture route remains authentication-free.
@MainActor
protocol DeviceSessionStoring {
    func load() -> StoredDeviceSession?
    func save(_ value: StoredDeviceSession) throws
    func delete()
    func loadPendingBootstrap() throws -> PendingDeviceSessionBootstrap?
    func savePendingBootstrap(_ value: PendingDeviceSessionBootstrap) throws
    func deletePendingBootstrap()
    func localOwnerID(for clerkID: String) -> String?
    func clerkID(forLocalOwnerID ownerID: String) -> String?
    func saveLocalOwnerID(_ ownerID: String, for clerkID: String)
    func removeLocalOwnerID(for clerkID: String)
}

struct DeviceSessionKeychainStore: DeviceSessionStoring {
    private let service = "com.shimizu-technology.media-tools.device-session"
    private let account = "first-party-ios-v1"
    private let pendingBootstrapAccount = "first-party-ios-bootstrap-v1"
    private let ownerMappingsKey = "verifiedLocalOwnerMappings.v1"

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
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(StoredDeviceSession.self, from: data)
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
    }

    func loadPendingBootstrap() throws -> PendingDeviceSessionBootstrap? {
        var query = baseQuery(account: pendingBootstrapAccount)
        query[kSecReturnData as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainFailure(status: status)
        }
        return try JSONDecoder().decode(PendingDeviceSessionBootstrap.self, from: data)
    }

    func savePendingBootstrap(_ value: PendingDeviceSessionBootstrap) throws {
        let data = try JSONEncoder().encode(value)
        let status = SecItemUpdate(
            baseQuery(account: pendingBootstrapAccount) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainFailure(status: status) }
        var attributes = baseQuery(account: pendingBootstrapAccount)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainFailure(status: addStatus) }
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

@MainActor
protocol DeletedClerkIdentityStoring: AnyObject {
    func contains(_ clerkID: String) -> Bool
    func insert(_ clerkID: String)
    func remove(_ clerkID: String)
    func removeAll(except clerkID: String?)
}

@MainActor
final class DeletedClerkIdentityStore: DeletedClerkIdentityStoring {
    static let shared = DeletedClerkIdentityStore()

    private let defaults: UserDefaults
    private let key = "locallyDeletedClerkIdentityIDs.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func contains(_ clerkID: String) -> Bool { values.contains(clerkID) }

    func insert(_ clerkID: String) {
        var updated = values
        updated.insert(clerkID)
        defaults.set(updated.sorted(), forKey: key)
    }

    func remove(_ clerkID: String) {
        var updated = values
        updated.remove(clerkID)
        persist(updated)
    }

    func removeAll(except clerkID: String?) {
        guard let clerkID else {
            defaults.removeObject(forKey: key)
            return
        }
        persist(values.contains(clerkID) ? [clerkID] : [])
    }

    private var values: Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    private func persist(_ values: Set<String>) {
        if values.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(values.sorted(), forKey: key)
        }
    }
}

private struct KeychainFailure: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Could not secure this device session (\(status))." }
}

@MainActor
@Observable
final class DeviceSessionController {
    static let shared = DeviceSessionController()

    private let store: any DeviceSessionStoring
    private let transport: any DeviceSessionTransport
    private let baseURL: URL
    private let enabled: Bool
    private let deletedClerkIdentities: any DeletedClerkIdentityStoring
    private var stored: StoredDeviceSession?
    private var refreshTask: Task<DeviceSessionPair, Error>?
    private var generation = 0

    private(set) var activeUserID: String?
    private(set) var needsSignIn = false
    private(set) var sessionRevision = 0

    init(transport: any DeviceSessionTransport = URLSession.shared,
         baseURL: URL = URL(string: Configuration.apiBaseURL + "/api/v1")!,
         store: (any DeviceSessionStoring)? = nil,
         deletedClerkIdentities: (any DeletedClerkIdentityStoring)? = nil,
         enabled: Bool = Configuration.firstPartyIOSAuthEnabled) {
        self.transport = transport
        self.baseURL = baseURL
        self.store = store ?? DeviceSessionKeychainStore()
        self.deletedClerkIdentities = deletedClerkIdentities ?? DeletedClerkIdentityStore.shared
        self.enabled = enabled
        // Keep the verified local-owner mapping available during an iOS flag
        // rollback without ever using its first-party bearer credential.
        self.stored = self.store.load()
        if let stored, stored.source == .clerk, let clerkID = stored.verifiedClerkID {
            self.store.saveLocalOwnerID(stored.pair.userID, for: clerkID)
        }
    }

    var verifiedMigration: (clerkID: String, userID: String)? {
        guard let stored, stored.source == .clerk, let clerkID = stored.verifiedClerkID,
              stored.pendingRevocation != true else { return nil }
        return (clerkID, stored.pair.userID)
    }

    var storedUserID: String? { stored?.pair.userID }

    var hasNativeFirstPartySession: Bool {
        guard let stored, stored.pendingRevocation != true else { return false }
        return stored.source != .clerk
    }

    func clerkIDForFallbackOwner(_ ownerID: String) -> String? {
        if let clerkID = Clerk.shared.user?.id,
           store.localOwnerID(for: clerkID) == ownerID { return clerkID }
        return store.clerkID(forLocalOwnerID: ownerID)
    }

    func markLocallyDeletedClerkIdentity(_ clerkID: String) {
        deletedClerkIdentities.insert(clerkID)
    }

    func clearLocallyDeletedClerkIdentity(_ clerkID: String) {
        deletedClerkIdentities.remove(clerkID)
    }

    func fallbackOwnerID(for clerkID: String?) -> String? {
        guard let clerkID else { return nil }
        return store.localOwnerID(for: clerkID) ?? clerkID
    }

    /// A 401 may retry through Clerk only when that Clerk account resolves to
    /// the same stable owner as the rejected device credential or request.
    func canFallbackToClerk(clerkID: String, expectedOwnerID: String?) -> Bool {
        guard !deletedClerkIdentities.contains(clerkID) else { return false }
        let requestOwnerID = expectedOwnerID ?? activeUserID ?? stored?.pair.userID
        guard let requestOwnerID else { return true }
        let clerkOwnerID = fallbackOwnerID(for: clerkID)
        return requestOwnerID == clerkOwnerID || requestOwnerID == clerkID
    }

    /// Called before exposing an account workspace. A different Clerk account
    /// suspends the old device credential rather than borrowing its local data.
    func activate(clerkID: String?) async -> String? {
        await activate(clerkID: clerkID, clerkIsLoaded: Clerk.shared.isLoaded)
    }

    func activate(clerkID: String?, clerkIsLoaded: Bool) async -> String? {
        // A nil user is authoritative only after Clerk has finished hydrating
        // its local cache. Preserve sign-out and deletion intent during the
        // earlier nil state so a cached identity cannot reappear on relaunch.
        if clerkID != nil || clerkIsLoaded {
            deletedClerkIdentities.removeAll(except: clerkID)
        }

        let hasUsableNativeSession: Bool
        if let stored {
            hasUsableNativeSession = enabled
                && stored.pendingRevocation != true
                && stored.source != .clerk
        } else {
            hasUsableNativeSession = false
        }

        // A retired Clerk subject may remain cached during an outage. It can
        // never bootstrap or reopen a fallback workspace. A durable native
        // session remains authoritative after Clerk detachment, even while
        // clearing that stale provider cache is temporarily unavailable.
        if !hasUsableNativeSession,
           await rejectRetiredClerkIdentity(clerkID) {
            return nil
        }
        guard enabled else {
            activeUserID = fallbackOwnerID(for: clerkID)
            return activeUserID
        }
        if let stored, stored.pendingRevocation == true {
            do {
                try await revokeAndClear()
            } catch {
                // A suspended credential is never used for the workspace.
                // Clerk can still serve a currently signed-in account.
                let ownerID = clerkID.flatMap { stored.belongs(to: $0) ? stored.pair.userID : fallbackOwnerID(for: $0) }
                activeUserID = ownerID
                return ownerID
            }
        }
        if needsSignIn {
            guard clerkID != nil else {
                activeUserID = nil
                return nil
            }
            clear()
            if await rejectRetiredClerkIdentity(clerkID) { return nil }
        }
        if let clerkID, let stored, stored.source == .clerk, !stored.belongs(to: clerkID) {
            do {
                try suspendForRevocation(stored)
            } catch {
                needsSignIn = true
            }
            activeUserID = fallbackOwnerID(for: clerkID)
            return activeUserID
        }
        if stored == nil, let clerkID {
            do {
                try await bootstrap(verifiedClerkID: clerkID)
            } catch {
                // A missing route or temporary outage can use the verified
                // migration fallback. Explicit identity rejection must fail
                // closed because it also means the Clerk link was detached.
                if Self.allowsClerkWorkspaceFallback(after: error),
                   let verifiedOwnerID = store.localOwnerID(for: clerkID) {
                    activeUserID = verifiedOwnerID
                } else {
                    activeUserID = nil
                    if Self.shouldClearRejectedClerkSession(after: error),
                       Clerk.shared.user?.id == clerkID {
                        try? await Clerk.shared.auth.signOut()
                    }
                }
                return activeUserID
            }
        }
        guard let stored else {
            activeUserID = fallbackOwnerID(for: clerkID)
            return activeUserID
        }
        if stored.pair.accessExpiresAt <= Date().addingTimeInterval(60) {
            do {
                _ = try await refresh()
            } catch {
                // Preserve the local session and recordings during a network
                // outage. A later API request retries the same rotation.
                if needsSignIn {
                    if let clerkID {
                        clear()
                        if await rejectRetiredClerkIdentity(clerkID) { return nil }
                        try? await bootstrap(verifiedClerkID: clerkID)
                    } else {
                        activeUserID = nil
                        return nil
                    }
                }
            }
        }
        if self.stored == nil,
           await rejectRetiredClerkIdentity(clerkID) {
            return nil
        }
        activeUserID = self.stored?.pair.userID ?? fallbackOwnerID(for: clerkID)
        return activeUserID
    }

    /// Prevent a locally retired provider identity from authenticating through
    /// any Clerk bootstrap or fallback path. A successful local Clerk sign-out
    /// releases ordinary sign-out blocks; deletion and detachment remain safe
    /// because the server has already removed that provider link.
    private func rejectRetiredClerkIdentity(_ clerkID: String?) async -> Bool {
        guard let clerkID, deletedClerkIdentities.contains(clerkID) else {
            return false
        }
        activeUserID = nil
        if Clerk.shared.user?.id == clerkID {
            try? await Clerk.shared.auth.signOut()
            if Clerk.shared.user?.id != clerkID {
                deletedClerkIdentities.remove(clerkID)
            }
        }
        return true
    }

    /// Returns nil only when the staged client has no first-party credential.
    func accessToken(expectedOwnerID: String?, forceRefresh: Bool,
                     forRevocation: Bool = false) async throws -> String? {
        guard enabled, let stored else { return nil }
        if stored.pendingRevocation == true && !forRevocation { return nil }
        if stored.source == .clerk,
           let verifiedClerkID = stored.verifiedClerkID,
           let currentClerkID = Clerk.shared.user?.id,
           currentClerkID != verifiedClerkID,
           !(forRevocation && stored.pendingRevocation == true) {
            throw APIError.authenticationRequired(
                message: "The signed-in account changed. Switch back to continue this upload."
            )
        }
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
        store.delete()
        store.deletePendingBootstrap()
        sessionRevision += 1
    }

    func prepareForNewNativeSession() async throws {
        guard enabled, stored != nil else { return }
        guard stored?.pendingRevocation != true else {
            throw APIError.authenticationRequired(message: "Finish signing out before switching accounts.")
        }
        try await revokeAndClear()
        guard stored == nil else {
            throw APIError.authenticationRequired(message: "Sign out before switching accounts.")
        }
    }

    func replaceSession(pair: DeviceSessionPair,
                        source: DeviceSessionSource,
                        verifiedClerkID: String? = nil) async throws {
        if let stored, stored.pair.sessionID != pair.sessionID {
            guard stored.pendingRevocation != true else {
                throw APIError.authenticationRequired(message: "Finish signing out before switching accounts.")
            }
            try await revokeAndClear()
        }
        try saveSession(pair: pair, source: source, verifiedClerkID: verifiedClerkID)
    }

    func saveSession(pair: DeviceSessionPair,
                     source: DeviceSessionSource,
                     verifiedClerkID: String? = nil) throws {
        guard enabled else { return }
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
        guard source != .clerk || verifiedClerkID != nil else {
            throw APIError.invalidResponse
        }
        let value = StoredDeviceSession(
            pair: pair,
            source: source,
            verifiedClerkID: verifiedClerkID,
            pendingNextRefreshToken: nil,
            pendingRevocation: nil
        )
        try store.save(value)
        if source == .clerk, let verifiedClerkID {
            store.saveLocalOwnerID(pair.userID, for: verifiedClerkID)
        }
        stored = value
        activeUserID = pair.userID
        needsSignIn = false
        generation += 1
        sessionRevision += 1
        refreshTask?.cancel()
        refreshTask = nil
    }

    func removeLocalOwnerMapping(clerkID: String) {
        store.removeLocalOwnerID(for: clerkID)
    }

    func removeLocalOwnerMappings(ownerID: String) {
        while let clerkID = store.clerkID(forLocalOwnerID: ownerID) {
            store.removeLocalOwnerID(for: clerkID)
        }
    }

    /// Preserve the device session while removing every local dependency on
    /// Clerk after the server confirms its one-way provider detachment.
    func markClerkDetached(expectedOwnerID: String) throws {
        guard var value = stored, value.pendingRevocation != true else {
            throw APIError.authenticationRequired(message: "Sign in again before disconnecting the old sign-in.")
        }
        guard value.pair.userID == expectedOwnerID else {
            throw APIError.authenticationRequired(message: "The signed-in account changed. Switch back and try again.")
        }
        var changed = false
        while let clerkID = store.clerkID(forLocalOwnerID: expectedOwnerID) {
            store.removeLocalOwnerID(for: clerkID)
            changed = true
        }
        if let clerkID = value.verifiedClerkID {
            store.removeLocalOwnerID(for: clerkID)
            changed = true
        }
        if value.source == .clerk {
            // Detachment is permitted only after a passkey exists. Reuse the
            // already-shipped passkey source value so a rollback build can
            // still decode and use this durable device session.
            value.source = .passkey
            changed = true
        }
        if value.verifiedClerkID != nil {
            value.verifiedClerkID = nil
            changed = true
        }
        guard changed else { return }
        if stored != value {
            try store.save(value)
            stored = value
        }
        generation += 1
        sessionRevision += 1
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
    }

    private func revoke(sessionID: String, forceRefresh: Bool) async throws {
        guard let token = try await accessToken(expectedOwnerID: stored?.pair.userID,
                                                forceRefresh: forceRefresh,
                                                forRevocation: true) else {
            throw APIError.authenticationRequired(message: "Sign in to finish signing out.")
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

    private func bootstrap(verifiedClerkID: String) async throws {
        guard let session = Clerk.shared.session,
              session.user?.id == verifiedClerkID else {
            throw APIError.authenticationRequired(message: "Sign in to connect this device.")
        }
        let clerkToken: String?
        do {
            clerkToken = try await session.getToken()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Clerk.shared.session?.id == session.id,
               Clerk.shared.session?.user?.id == verifiedClerkID {
                throw APIError.authenticationTemporarilyUnavailable(
                    message: "The sign-in service is temporarily unavailable. Media Tools will retry."
                )
            }
            throw APIError.authenticationRequired(message: "Sign in to connect this device.")
        }
        guard let clerkToken, !clerkToken.isEmpty,
              Clerk.shared.session?.id == session.id,
              Clerk.shared.session?.user?.id == verifiedClerkID else {
            throw APIError.authenticationRequired(message: "Sign in to connect this device.")
        }
        try await bootstrap(
            verifiedClerkID: verifiedClerkID,
            clerkToken: clerkToken,
            currentClerkID: { Clerk.shared.session?.user?.id }
        )
    }

    func bootstrapForTesting(verifiedClerkID: String, clerkToken: String) async throws {
        try await bootstrap(
            verifiedClerkID: verifiedClerkID,
            clerkToken: clerkToken,
            currentClerkID: { verifiedClerkID }
        )
    }

    private func bootstrap(verifiedClerkID: String,
                           clerkToken: String,
                           currentClerkID: () -> String?) async throws {
        let startingGeneration = generation
        var pending = try store.loadPendingBootstrap()
        if pending?.verifiedClerkID != verifiedClerkID {
            store.deletePendingBootstrap()
            pending = nil
        }
        if pending == nil {
            pending = PendingDeviceSessionBootstrap(
                verifiedClerkID: verifiedClerkID,
                nextRefreshToken: try Self.randomRefreshToken()
            )
            try store.savePendingBootstrap(pending!)
        }
        guard let pending else { throw APIError.invalidResponse }

        var request = URLRequest(url: baseURL.appendingPathComponent("auth/session/bootstrap"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(clerkToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_type": "ios",
            "device_name": "iPhone",
            "next_refresh_token": pending.nextRefreshToken,
        ])
        let pair: DeviceSessionPair
        do {
            pair = try await sendPairRequest(request)
        } catch APIError.httpError(let status, _, _) where status == 400 || status == 401 {
            store.deletePendingBootstrap()
            throw APIError.authenticationRequired(message: "Sign in to connect this device.")
        }
        guard startingGeneration == generation,
              currentClerkID() == verifiedClerkID,
              !Task.isCancelled else { throw CancellationError() }
        guard !pair.userID.isEmpty, !pair.sessionID.isEmpty,
              !pair.accessToken.isEmpty, pair.refreshToken == pending.nextRefreshToken else {
            throw APIError.invalidResponse
        }
        try saveSession(pair: pair, source: .clerk, verifiedClerkID: verifiedClerkID)
        store.deletePendingBootstrap()
    }

    static func allowsClerkWorkspaceFallback(after error: Error) -> Bool {
        switch error {
        case APIError.httpError(let status, _, _):
            return status == 404 || status >= 500
        case APIError.authenticationTemporarilyUnavailable:
            return true
        case is URLError:
            return true
        default:
            return false
        }
    }

    static func shouldClearRejectedClerkSession(after error: Error) -> Bool {
        switch error {
        case APIError.authenticationRequired:
            return true
        case APIError.httpError(let status, _, _):
            return status == 400 || status == 401 || status == 403 || status == 409
        default:
            return false
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
            throw APIError.authenticationRequired(message: "Sign in to continue.")
        }
        guard startingGeneration == generation,
              stored?.pair.sessionID == value.pair.sessionID,
              stored?.pendingNextRefreshToken == next,
              value.source != .clerk
                || Clerk.shared.user?.id == nil
                || Clerk.shared.user?.id == value.verifiedClerkID
                || value.pendingRevocation == true,
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
