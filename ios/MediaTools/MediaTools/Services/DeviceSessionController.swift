import Foundation
import Observation
import Security
import ClerkKit

/// Credentials issued by the Media Tools API after a verified Clerk bootstrap.
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

struct StoredDeviceSession: Codable, Equatable {
    var pair: DeviceSessionPair
    let verifiedClerkID: String
    /// Written before refresh so a lost response can retry the same rotation.
    var pendingNextRefreshToken: String?
}

/// App-only Keychain item. The future Share Extension must not receive this
/// credential; its signed-out capture route remains authentication-free.
@MainActor
protocol DeviceSessionStoring {
    func load() -> StoredDeviceSession?
    func save(_ value: StoredDeviceSession) throws
    func delete()
}

struct DeviceSessionKeychainStore: DeviceSessionStoring {
    private let service = "com.shimizu-technology.media-tools.device-session"
    private let account = "first-party-ios-v1"

    func load() -> StoredDeviceSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(StoredDeviceSession.self, from: data)
    }

    func save(_ value: StoredDeviceSession) throws {
        let data = try JSONEncoder().encode(value)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainFailure(status: status) }
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainFailure(status: addStatus) }
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
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
    private var stored: StoredDeviceSession?
    private var refreshTask: Task<DeviceSessionPair, Error>?
    private var generation = 0

    private(set) var activeUserID: String?
    private(set) var needsSignIn = false

    init(transport: any DeviceSessionTransport = URLSession.shared,
         baseURL: URL = URL(string: Configuration.apiBaseURL + "/api/v1")!,
         store: (any DeviceSessionStoring)? = nil,
         enabled: Bool = Configuration.firstPartyIOSAuthEnabled) {
        self.transport = transport
        self.baseURL = baseURL
        self.store = store ?? DeviceSessionKeychainStore()
        self.enabled = enabled
        self.stored = enabled ? self.store.load() : nil
    }

    var verifiedMigration: (clerkID: String, userID: String)? {
        guard let stored else { return nil }
        return (stored.verifiedClerkID, stored.pair.userID)
    }

    /// Called before exposing an account workspace. A different Clerk account
    /// suspends the old device credential rather than borrowing its local data.
    func activate(clerkID: String?) async -> String? {
        guard enabled else {
            activeUserID = clerkID
            return clerkID
        }
        if needsSignIn {
            guard clerkID != nil else {
                activeUserID = nil
                return nil
            }
            clear()
        }
        if let clerkID, let stored, stored.verifiedClerkID != clerkID {
            clear()
        }
        if stored == nil, let clerkID {
            do {
                try await bootstrap(verifiedClerkID: clerkID)
            } catch {
                // The server rollout may be disabled. Clerk remains the safe
                // fallback for this already signed-in account.
                activeUserID = clerkID
                return clerkID
            }
        }
        guard let stored else {
            activeUserID = clerkID
            return clerkID
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
                        try? await bootstrap(verifiedClerkID: clerkID)
                    } else {
                        activeUserID = nil
                        return nil
                    }
                }
            }
        }
        activeUserID = self.stored?.pair.userID ?? clerkID
        return activeUserID
    }

    /// Returns nil only when the staged client has no first-party credential.
    func accessToken(expectedOwnerID: String?, forceRefresh: Bool) async throws -> String? {
        guard enabled, let stored else { return nil }
        if let currentClerkID = Clerk.shared.user?.id,
           currentClerkID != stored.verifiedClerkID {
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

    private func revoke(sessionID: String, forceRefresh: Bool) async throws {
        guard let token = try await accessToken(expectedOwnerID: stored?.pair.userID,
                                                forceRefresh: forceRefresh) else {
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
        let startingGeneration = generation
        guard let session = Clerk.shared.session,
              session.user?.id == verifiedClerkID,
              let clerkToken = try await session.getToken() else {
            throw APIError.authenticationRequired(message: "Sign in to connect this device.")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/session/bootstrap"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(clerkToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_type": "ios",
            "device_name": "iPhone",
        ])
        let pair = try await sendPairRequest(request)
        guard startingGeneration == generation,
              Clerk.shared.session?.user?.id == verifiedClerkID,
              !Task.isCancelled else { throw CancellationError() }
        guard !pair.userID.isEmpty, !pair.sessionID.isEmpty,
              !pair.accessToken.isEmpty, !pair.refreshToken.isEmpty else {
            throw APIError.invalidResponse
        }
        let value = StoredDeviceSession(pair: pair, verifiedClerkID: verifiedClerkID,
                                        pendingNextRefreshToken: nil)
        try store.save(value)
        stored = value
        needsSignIn = false
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
              Clerk.shared.user?.id == nil || Clerk.shared.user?.id == value.verifiedClerkID,
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
