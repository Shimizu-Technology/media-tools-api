import ClerkKit
import Foundation
import Security

struct PendingAccountDeletion: Codable, Equatable {
    let ownerID: String
    let receiptToken: String
}

struct AccountDeletionReceiptResponse: Decodable, Equatable {
    let confirmed: Bool
}

struct AccountDeletionRequestBody: Encodable, Equatable {
    let confirmation: String
    let deletionReceiptToken: String

    enum CodingKeys: String, CodingKey {
        case confirmation
        case deletionReceiptToken = "deletion_receipt_token"
    }
}

struct AccountDeletionReceiptRequestBody: Encodable, Equatable {
    let deletionReceiptToken: String

    enum CodingKeys: String, CodingKey {
        case deletionReceiptToken = "deletion_receipt_token"
    }
}

protocol AccountDeletionAPI: Sendable {
    func requestAccountDeletion(ownerID: String, receiptToken: String) async throws
    func accountDeletionReceiptConfirmed(_ receiptToken: String) async throws -> Bool
}

@MainActor
protocol AccountDeletionLocalDataRemoving: AnyObject {
    func removeLocalAccountData(ownerID: String) async
}

extension RecordingUploadCoordinator: AccountDeletionLocalDataRemoving {}

extension APIClient: AccountDeletionAPI {
    func requestAccountDeletion(ownerID: String, receiptToken: String) async throws {
        try await delete(
            "/account",
            body: AccountDeletionRequestBody(
                confirmation: "DELETE",
                deletionReceiptToken: receiptToken
            ),
            expectedOwnerID: ownerID
        )
    }

    func accountDeletionReceiptConfirmed(_ receiptToken: String) async throws -> Bool {
        let response: AccountDeletionReceiptResponse = try await postPublic(
            "/account/deletion-status",
            body: AccountDeletionReceiptRequestBody(deletionReceiptToken: receiptToken)
        )
        return response.confirmed
    }
}

@MainActor
protocol AccountDeletionJournaling: AnyObject {
    func load() throws -> PendingAccountDeletion?
    func save(_ value: PendingAccountDeletion) throws
    func delete()
}

enum AccountDeletionRecoveryError: LocalizedError, Equatable {
    case pendingForAnotherAccount
    case couldNotConfirm
    case couldNotCreateReceipt

    var errorDescription: String? {
        switch self {
        case .pendingForAnotherAccount:
            return "Media Tools is still confirming a previous account deletion. Reopen the app and try again."
        case .couldNotConfirm:
            return "Media Tools could not confirm that deletion completed. Your account and recordings remain on this iPhone. Check your connection and try again."
        case .couldNotCreateReceipt:
            return "Media Tools could not secure this deletion request. Restart the app and try again."
        }
    }
}

@MainActor
final class AccountDeletionRecoveryService {
    static let shared = AccountDeletionRecoveryService()

    private let api: any AccountDeletionAPI
    private let journal: any AccountDeletionJournaling

    init(
        api: any AccountDeletionAPI = APIClient.shared,
        journal: (any AccountDeletionJournaling)? = nil
    ) {
        self.api = api
        self.journal = journal ?? AccountDeletionKeychainJournal.shared
    }

    /// Persist the receipt before sending DELETE. Retrying for the same owner
    /// always reuses the exact receipt, including after a crash or lost reply.
    func prepare(ownerID: String) throws -> PendingAccountDeletion {
        if let pending = try journal.load() {
            guard pending.ownerID == ownerID else {
                throw AccountDeletionRecoveryError.pendingForAnotherAccount
            }
            return pending
        }
        let pending = PendingAccountDeletion(
            ownerID: ownerID,
            receiptToken: try Self.randomReceiptToken()
        )
        try journal.save(pending)
        return pending
    }

    /// A successful DELETE is proof that the transaction committed. For every
    /// thrown response, including 401 or 409, the public receipt is the only
    /// safe way to distinguish a rejected request from a lost success reply.
    func requestDeletion(ownerID: String) async throws -> PendingAccountDeletion {
        let pending = try prepare(ownerID: ownerID)
        do {
            try await api.requestAccountDeletion(
                ownerID: ownerID,
                receiptToken: pending.receiptToken
            )
            return pending
        } catch {
            if (try? await api.accountDeletionReceiptConfirmed(pending.receiptToken)) == true {
                return pending
            }
            throw AccountDeletionRecoveryError.couldNotConfirm
        }
    }

    /// Called before restoring a workspace. A false or unavailable lookup is
    /// deliberately non-destructive and leaves the journal available to retry.
    func confirmedPendingDeletion(retryOwnerID: String? = nil) async throws -> PendingAccountDeletion? {
        guard let pending = try journal.load() else { return nil }
        if try await api.accountDeletionReceiptConfirmed(pending.receiptToken) {
            return pending
        }
        guard retryOwnerID == pending.ownerID else {
            return nil
        }
        do {
            try await api.requestAccountDeletion(
                ownerID: pending.ownerID,
                receiptToken: pending.receiptToken
            )
            return pending
        } catch {
            guard (try? await api.accountDeletionReceiptConfirmed(pending.receiptToken)) == true else {
                return nil
            }
            return pending
        }
    }

    /// Local recording cleanup records its own durable retry marker. Once that
    /// marker is written, the server receipt journal can be removed safely.
    func finishLocalDeletion(
        _ pending: PendingAccountDeletion,
        uploadCoordinator: any AccountDeletionLocalDataRemoving,
        consent: AIProcessingConsentManager,
        deviceSession: DeviceSessionController,
        tokenSync: TokenSyncService,
        clerk: Clerk
    ) async throws {
        guard try journal.load() == pending else {
            throw AccountDeletionRecoveryError.couldNotConfirm
        }

        let ownerID = pending.ownerID
        let migrationClerkID = deviceSession.verifiedMigration
            .flatMap { $0.userID == ownerID ? $0.clerkID : nil }
        // Capture the exact provider identity before its local mapping is
        // removed. Every decision about current auth state is made again after
        // file cleanup, which can suspend while the user switches accounts.
        let clerkIDBeforeCleanup = clerk.user?.id
        let deletedClerkID: String?
        if let clerkIDBeforeCleanup,
           deviceSession.fallbackOwnerID(for: clerkIDBeforeCleanup) == ownerID {
            deletedClerkID = clerkIDBeforeCleanup
        } else {
            deletedClerkID = migrationClerkID
        }

        await uploadCoordinator.removeLocalAccountData(ownerID: ownerID)
        consent.removeConsent(ownerID: ownerID)
        if let migrationClerkID {
            consent.removeConsent(ownerID: migrationClerkID)
        }
        if let deletedClerkID {
            // Keep the deleted provider blocked across relaunch until Clerk is
            // actually gone locally. A failed sign-out must never reopen a
            // fallback workspace under the deleted provider subject.
            deviceSession.markLocallyDeletedClerkIdentity(deletedClerkID)
        }
        deviceSession.removeLocalOwnerMappings(ownerID: ownerID)
        journal.delete()

        let shouldClearDeviceSession = deviceSession.storedUserID == ownerID
            || deviceSession.activeUserID == ownerID
        let shouldSignOutClerk = deletedClerkID != nil
            && clerk.user?.id == deletedClerkID
        guard shouldClearDeviceSession || shouldSignOutClerk else {
            return
        }
        if shouldClearDeviceSession {
            FirstPartyAuthService.shared.clearSessionScopedJournals()
            deviceSession.clear()
        }
        tokenSync.stopSyncing()
        tokenSync.clearToken()
        if shouldSignOutClerk {
            try? await clerk.auth.signOut()
        }
        if let deletedClerkID, clerk.user?.id != deletedClerkID {
            deviceSession.clearLocallyDeletedClerkIdentity(deletedClerkID)
        }
    }

    static func randomReceiptToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AccountDeletionRecoveryError.couldNotCreateReceipt
        }
        return "mta_del_" + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
final class AccountDeletionKeychainJournal: AccountDeletionJournaling {
    static let shared = AccountDeletionKeychainJournal()

    private let service = "com.shimizu-technology.media-tools.account-deletion"
    private let account = "account-deletion-receipt-v1"

    func load() throws -> PendingAccountDeletion? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw AccountDeletionRecoveryError.couldNotCreateReceipt
        }
        do {
            return try JSONDecoder().decode(PendingAccountDeletion.self, from: data)
        } catch {
            // Corrupt state cannot safely be rebound to whichever account is
            // active. Preserve no ambiguous credential and require a fresh tap.
            delete()
            throw AccountDeletionRecoveryError.couldNotCreateReceipt
        }
    }

    func save(_ value: PendingAccountDeletion) throws {
        let data = try JSONEncoder().encode(value)
        let status = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw AccountDeletionRecoveryError.couldNotCreateReceipt
        }
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw AccountDeletionRecoveryError.couldNotCreateReceipt
        }
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
