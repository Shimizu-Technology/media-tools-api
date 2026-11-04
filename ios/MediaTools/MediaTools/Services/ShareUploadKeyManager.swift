import Foundation

struct ShareUploadKeyResponse: Decodable, Equatable {
    let id: String
    let rawKey: String
}

struct ListedAPIKey: Decodable, Equatable {
    let id: String
    let name: String
    let active: Bool
    let scopes: [String]?
}

struct CreateShareUploadKeyRequest: Encodable, Equatable {
    let name: String
    let scopes: [String]
}

protocol ShareUploadKeyAPI: Sendable {
    func createShareUploadKey(name: String, ownerID: String) async throws -> ShareUploadKeyResponse
    func listAPIKeys(ownerID: String) async throws -> [ListedAPIKey]
    func listAPIKeys(bearerToken: String) async throws -> [ListedAPIKey]
    func revokeAPIKey(id: String, ownerID: String) async throws
    func revokeAPIKey(id: String, bearerToken: String) async throws
}

extension APIClient: ShareUploadKeyAPI {
    func createShareUploadKey(name: String, ownerID: String) async throws -> ShareUploadKeyResponse {
        try await post(
            "/user/keys",
            body: CreateShareUploadKeyRequest(name: name, scopes: ["capture:upload"]),
            expectedOwnerID: ownerID
        )
    }

    func listAPIKeys(ownerID: String) async throws -> [ListedAPIKey] {
        try await get("/keys", expectedOwnerID: ownerID)
    }

    func listAPIKeys(bearerToken: String) async throws -> [ListedAPIKey] {
        try await get("/keys", bearerToken: bearerToken)
    }

    func revokeAPIKey(id: String, ownerID: String) async throws {
        try await delete("/keys/\(id)", body: EmptyRequest(), expectedOwnerID: ownerID)
    }

    func revokeAPIKey(id: String, bearerToken: String) async throws {
        try await delete("/keys/\(id)", bearerToken: bearerToken)
    }
}

/// Owns the capture-only key that lets a share upload without opening the app.
///
/// The key follows the device session: minted once a session exists, gone from this
/// iPhone the moment that session ends, for any reason. Nothing here may block
/// sign-in, sign-out, or a share. Without a key, a share waits for the app.
@MainActor
final class ShareUploadKeyManager {
    static let shared = ShareUploadKeyManager()

    /// A key the server may still consider active, though no one here can use it.
    /// Only a session of that account can revoke it, which may be much later.
    private struct PendingRevocation: Codable, Equatable {
        let keyID: String
        let ownerID: String
    }

    private static let pendingRevocationsKey = "shareUploadKeyPendingRevocations.v1"
    private static let installIDKey = "shareUploadKeyInstallID.v1"
    /// The key for which this install is known to hold no other active key.
    private static let reconciledKeyIDKey = "shareUploadKeyReconciledKeyID.v1"
    private static let maximumPendingRevocations = 16

    private let credentials: any ShareUploadCredentialStoring
    private let api: any ShareUploadKeyAPI
    private let defaults: UserDefaults
    /// Bumped whenever the credential ends, so a mint already on the wire cannot
    /// install a key for a session that no longer exists.
    private var generation = 0
    private var mintInProgress = false

    init(
        credentials: any ShareUploadCredentialStoring = ShareUploadKeychainStore(),
        api: any ShareUploadKeyAPI = APIClient.shared,
        defaults: UserDefaults = .standard
    ) {
        self.credentials = credentials
        self.api = api
        self.defaults = defaults
    }

    /// Ties this key to the session that keeps it valid.
    func follow(_ session: DeviceSessionController) {
        session.onCredentialEnded = { [weak self] in
            self?.endCredential()
        }
        session.beforeSessionRevocation = { [weak self] bearerToken, ownerID in
            await self?.revokeBeforeSessionEnds(bearerToken: bearerToken, ownerID: ownerID)
        }
    }

    /// Called at sign-in, and on each launch for a session that predates this
    /// feature. A missing key just means another try on the next foreground.
    func ensureKey(ownerID: String) async {
        guard !mintInProgress else { return }
        mintInProgress = true
        defer { mintInProgress = false }

        await flushPendingRevocations(ownerID: ownerID)
        switch credentials.load() {
        case .found(let credential) where credential.ownerID == ownerID:
            await reconcileInstallKeys(keeping: credential.keyID, ownerID: ownerID)
            return
        case .found:
            endCredential()
        case .missing:
            break
        case .unavailable:
            // Locked, or a build with no entitlement. A key minted now could not be
            // saved, and would be one more for the account to clean up.
            return
        }

        let startingGeneration = generation
        let name = keyName
        do {
            let key = try await api.createShareUploadKey(name: name, ownerID: ownerID)
            guard generation == startingGeneration, !Task.isCancelled else {
                addPendingRevocation(PendingRevocation(keyID: key.id, ownerID: ownerID))
                return
            }
            do {
                try credentials.save(
                    ShareUploadCredential(keyID: key.id, rawKey: key.rawKey, ownerID: ownerID)
                )
            } catch {
                addPendingRevocation(PendingRevocation(keyID: key.id, ownerID: ownerID))
                await flushPendingRevocations(ownerID: ownerID)
                return
            }
            await reconcileInstallKeys(keeping: key.id, ownerID: ownerID)
        } catch {
            // Offline, capped, or a server without scoped keys. Shares still save.
        }
    }

    /// Stops the extension immediately. The server side follows when it can, so
    /// the key's ID is remembered until a session of that account can revoke it.
    func endCredential() {
        generation += 1
        if case .found(let credential) = credentials.load() {
            addPendingRevocation(
                PendingRevocation(keyID: credential.keyID, ownerID: credential.ownerID)
            )
        }
        credentials.delete()
        defaults.removeObject(forKey: Self.reconciledKeyIDKey)
    }

    /// The server deletes an account's keys with the account, so there is nothing
    /// to revoke later, and no account that could.
    func accountDeleted(ownerID: String) {
        generation += 1
        if case .found(let credential) = credentials.load(), credential.ownerID == ownerID {
            credentials.delete()
            defaults.removeObject(forKey: Self.reconciledKeyIDKey)
        }
        savePendingRevocations(pendingRevocations.filter { $0.ownerID != ownerID })
    }

    private func revokeBeforeSessionEnds(bearerToken: String, ownerID: String) async {
        var mayHaveOrphans = true
        if case .found(let credential) = credentials.load(), credential.ownerID == ownerID {
            mayHaveOrphans = defaults.string(forKey: Self.reconciledKeyIDKey) != credential.keyID
            endCredential()
        }
        // This session is the last thing that can find an orphan's ID. If the list
        // fails, the next session of this account reconciles from the name instead.
        if mayHaveOrphans, let keys = try? await api.listAPIKeys(bearerToken: bearerToken) {
            rememberInstallKeys(in: keys, keeping: nil, ownerID: ownerID)
        }
        for pending in pendingRevocations where pending.ownerID == ownerID {
            do {
                try await api.revokeAPIKey(id: pending.keyID, bearerToken: bearerToken)
                removePendingRevocation(pending)
            } catch where Self.keyIsAlreadyGone(error) {
                removePendingRevocation(pending)
            } catch {
                // Kept for the next session of this account.
            }
        }
    }

    private func flushPendingRevocations(ownerID: String) async {
        for pending in pendingRevocations where pending.ownerID == ownerID {
            do {
                try await api.revokeAPIKey(id: pending.keyID, ownerID: ownerID)
                removePendingRevocation(pending)
            } catch where Self.keyIsAlreadyGone(error) {
                removePendingRevocation(pending)
            } catch {
                // Tried again on the next launch.
            }
        }
    }

    /// A mint whose response was lost leaves a key no one holds. Its name is unique
    /// to this install, so that is the one thing it can safely be found by.
    ///
    /// A key found here joins the pending list, so its ID survives a failed revoke.
    /// Nothing is marked done until the list is empty, so a failed list or revoke
    /// repeats on the next launch even though the saved key is simply reused.
    private func reconcileInstallKeys(keeping keptID: String, ownerID: String) async {
        guard defaults.string(forKey: Self.reconciledKeyIDKey) != keptID else { return }
        let startingGeneration = generation
        guard let keys = try? await api.listAPIKeys(ownerID: ownerID) else { return }
        rememberInstallKeys(in: keys, keeping: keptID, ownerID: ownerID)
        await flushPendingRevocations(ownerID: ownerID)
        guard generation == startingGeneration,
              !pendingRevocations.contains(where: { $0.ownerID == ownerID })
        else { return }
        defaults.set(keptID, forKey: Self.reconciledKeyIDKey)
    }

    private func rememberInstallKeys(in keys: [ListedAPIKey], keeping keptID: String?, ownerID: String) {
        let name = keyName
        for key in keys where key.active && key.name == name && key.id != keptID {
            addPendingRevocation(PendingRevocation(keyID: key.id, ownerID: ownerID))
        }
    }

    private static func keyIsAlreadyGone(_ error: Error) -> Bool {
        if case APIError.httpError(404, _, _) = error { return true }
        return false
    }

    private var keyName: String {
        if let installID = defaults.string(forKey: Self.installIDKey) {
            return "iPhone share upload \(installID)"
        }
        let installID = String(UUID().uuidString.prefix(8)).lowercased()
        defaults.set(installID, forKey: Self.installIDKey)
        return "iPhone share upload \(installID)"
    }

    private var pendingRevocations: [PendingRevocation] {
        guard let data = defaults.data(forKey: Self.pendingRevocationsKey) else { return [] }
        return (try? JSONDecoder().decode([PendingRevocation].self, from: data)) ?? []
    }

    private func addPendingRevocation(_ pending: PendingRevocation) {
        var updated = pendingRevocations.filter { $0 != pending }
        updated.append(pending)
        savePendingRevocations(Array(updated.suffix(Self.maximumPendingRevocations)))
    }

    private func removePendingRevocation(_ pending: PendingRevocation) {
        savePendingRevocations(pendingRevocations.filter { $0 != pending })
    }

    private func savePendingRevocations(_ values: [PendingRevocation]) {
        if values.isEmpty {
            defaults.removeObject(forKey: Self.pendingRevocationsKey)
        } else if let data = try? JSONEncoder().encode(values) {
            defaults.set(data, forKey: Self.pendingRevocationsKey)
        }
    }
}
