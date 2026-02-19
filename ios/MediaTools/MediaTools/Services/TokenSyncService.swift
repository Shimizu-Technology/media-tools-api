import Foundation
import ClerkKit

/// Syncs the Clerk session token to Keychain periodically
/// so the Share Extension can use it.
@Observable
final class TokenSyncService {
    static let shared = TokenSyncService()

    private var syncTask: Task<Void, Never>?
    private(set) var lastSyncedAt: Date?

    /// Start syncing the Clerk session token to Keychain every 50 seconds.
    func startSyncing() {
        stopSyncing()
        syncTask = Task {
            while !Task.isCancelled {
                await syncToken()
                try? await Task.sleep(for: .seconds(50))
            }
        }
    }

    /// Stop the sync loop.
    func stopSyncing() {
        syncTask?.cancel()
        syncTask = nil
    }

    /// Sync once (call on sign-in).
    func syncToken() async {
        do {
            if let token = try await Clerk.shared.session?.getToken() {
                KeychainService.saveToken(token)
                lastSyncedAt = Date()
            }
        } catch {
            print("Token sync failed: \(error)")
        }
    }

    /// Clear token (call on sign-out).
    func clearToken() {
        KeychainService.deleteToken()
        lastSyncedAt = nil
    }
}
