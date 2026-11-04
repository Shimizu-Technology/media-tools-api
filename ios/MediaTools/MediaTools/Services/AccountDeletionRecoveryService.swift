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
    var currentPassword: String? = nil

    enum CodingKeys: String, CodingKey {
        case confirmation
        case deletionReceiptToken = "deletion_receipt_token"
        case currentPassword = "current_password"
    }
}

struct AccountDeletionReceiptRequestBody: Encodable, Equatable {
    let deletionReceiptToken: String

    enum CodingKeys: String, CodingKey {
        case deletionReceiptToken = "deletion_receipt_token"
    }
}

protocol AccountDeletionAPI: Sendable {
    func requestAccountDeletion(ownerID: String, receiptToken: String, currentPassword: String?) async throws
    func accountDeletionReceiptConfirmed(_ receiptToken: String) async throws -> Bool
}

@MainActor
protocol AccountDeletionLocalDataRemoving: AnyObject {
    func removeLocalAccountData(ownerID: String) async
}

extension RecordingUploadCoordinator: AccountDeletionLocalDataRemoving {}

extension APIClient: AccountDeletionAPI {
    func requestAccountDeletion(ownerID: String, receiptToken: String, currentPassword: String?) async throws {
        // Encoded by the shared snake-case encoder, which leaves the explicit
        // keys above untouched.
        try await delete(
            "/account",
            body: AccountDeletionRequestBody(
                confirmation: "DELETE",
                deletionReceiptToken: receiptToken,
                currentPassword: currentPassword
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
    case currentPasswordRejected

    var errorDescription: String? {
        switch self {
        case .pendingForAnotherAccount:
            return "Media Tools is still confirming a previous account deletion. Reopen the app and try again."
        case .couldNotConfirm:
            return "Media Tools could not confirm that deletion completed. Your account and recordings remain on this iPhone. Check your connection and try again."
        case .couldNotCreateReceipt:
            return "Media Tools could not secure this deletion request. Restart the app and try again."
        case .currentPasswordRejected:
            return "Your current password is incorrect. Your account was not deleted."
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

    /// Local read used before opening a stored workspace. A deletion that might
    /// have committed must be reconciled before showing that account's content.
    var hasPendingDeletion: Bool {
        (try? journal.load()) != nil
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
    func requestDeletion(ownerID: String, currentPassword: String? = nil) async throws -> PendingAccountDeletion {
        let pending = try prepare(ownerID: ownerID)
        do {
            try await api.requestAccountDeletion(
                ownerID: ownerID,
                receiptToken: pending.receiptToken,
                currentPassword: currentPassword
            )
            return pending
        } catch let requestError {
            do {
                if try await api.accountDeletionReceiptConfirmed(pending.receiptToken) {
                    return pending
                }
                // An HTTP response proves the DELETE finished. When its
                // receipt is also absent, do not replay that rejected request
                // later without a fresh user confirmation.
                if Self.isDefinitiveRejection(requestError) {
                    journal.delete()
                    if case APIError.httpError(_, "current_password_required", _) = requestError {
                        throw AccountDeletionRecoveryError.currentPasswordRejected
                    }
                }
            } catch let error as AccountDeletionRecoveryError {
                throw error
            } catch {
                // A failed receipt lookup leaves the outcome unknown. Keep the
                // exact journal so the same request can be reconciled later.
            }
            throw AccountDeletionRecoveryError.couldNotConfirm
        }
    }

    /// Called before restoring a workspace. An initial false or unavailable
    /// lookup preserves the journal. A same-owner retry clears it only when an
    /// HTTP rejection plus a second false lookup proves deletion did not commit.
    func confirmedPendingDeletion(retryOwnerID: String? = nil) async throws -> PendingAccountDeletion? {
        guard let pending = try journal.load() else { return nil }
        if try await api.accountDeletionReceiptConfirmed(pending.receiptToken) {
            return pending
        }
        guard retryOwnerID == pending.ownerID else {
            return nil
        }
        do {
            // The password is never saved, so a password account's retry is rejected
            // and its journal cleared, leaving the account for a fresh confirmation.
            try await api.requestAccountDeletion(
                ownerID: pending.ownerID,
                receiptToken: pending.receiptToken,
                currentPassword: nil
            )
            return pending
        } catch let requestError {
            do {
                if try await api.accountDeletionReceiptConfirmed(pending.receiptToken) {
                    return pending
                }
                if Self.isDefinitiveRejection(requestError) {
                    journal.delete()
                }
            } catch {
                // Keep an indeterminate request journal for a later exact
                // receipt lookup; never infer deletion from a transport error.
            }
            return nil
        }
    }

    /// What launch learned about a deletion journal. Only `.none` and `.completed`
    /// let a stored workspace open: while a deletion might have committed, that
    /// account's content, consent, and uploads stay closed.
    enum PendingDeletionResolution: Equatable {
        case none
        case completed
        case unresolved
    }

    /// Reconciles a journal before the stored account opens. A lookup that
    /// cannot finish, a cleanup that cannot finish, or an unproven retry for the
    /// signed-in account is `.unresolved`, never "no deletion". A journal for a
    /// different account does not block this one.
    func resolvePendingDeletion(
        retryOwnerID: String?,
        uploadCoordinator: any AccountDeletionLocalDataRemoving,
        consent: AIProcessingConsentManager,
        deviceSession: DeviceSessionController,
        shareKeys: ShareUploadKeyManager
    ) async -> PendingDeletionResolution {
        guard (try? journal.load()) != nil else { return .none }
        let confirmed: PendingAccountDeletion?
        do {
            confirmed = try await confirmedPendingDeletion(retryOwnerID: retryOwnerID)
        } catch {
            return .unresolved
        }
        if let confirmed {
            do {
                try await finishLocalDeletion(
                    confirmed,
                    uploadCoordinator: uploadCoordinator,
                    consent: consent,
                    deviceSession: deviceSession,
                    shareKeys: shareKeys
                )
                return .completed
            } catch {
                return .unresolved
            }
        }
        if let remaining = try? journal.load(), remaining.ownerID == retryOwnerID {
            return .unresolved
        }
        return .none
    }

    private static func isDefinitiveRejection(_ error: Error) -> Bool {
        guard case APIError.httpError(let statusCode, let code, _) = error else {
            return false
        }
        if statusCode == 400 || statusCode == 401 || statusCode == 403 {
            return true
        }
        // This application response is emitted before the deletion database
        // transaction starts. Generic 5xx responses stay ambiguous because a
        // proxy error or lost commit acknowledgement may race the receipt read.
        return statusCode == 503 && code == "account_deletion_unavailable"
    }

    /// Local recording cleanup records its own durable retry marker. Once that
    /// marker is written, the server receipt journal can be removed safely.
    func finishLocalDeletion(
        _ pending: PendingAccountDeletion,
        uploadCoordinator: any AccountDeletionLocalDataRemoving,
        consent: AIProcessingConsentManager,
        deviceSession: DeviceSessionController,
        shareKeys: ShareUploadKeyManager
    ) async throws {
        guard try journal.load() == pending else {
            throw AccountDeletionRecoveryError.couldNotConfirm
        }

        let ownerID = pending.ownerID
        let legacyOwnerID = deviceSession.verifiedMigration
            .flatMap { $0.userID == ownerID ? $0.clerkID : nil }

        // The server deleted this account's keys with it. Stopping the extension
        // comes first, so a share made during cleanup is saved rather than sent.
        shareKeys.accountDeleted(ownerID: ownerID)
        await uploadCoordinator.removeLocalAccountData(ownerID: ownerID)
        consent.removeConsent(ownerID: ownerID)
        if let legacyOwnerID {
            consent.removeConsent(ownerID: legacyOwnerID)
        }
        deviceSession.removeLocalOwnerMappings(ownerID: ownerID)
        journal.delete()

        guard deviceSession.storedUserID == ownerID || deviceSession.activeUserID == ownerID else {
            return
        }
        FirstPartyAuthService.shared.clearSessionScopedJournals()
        deviceSession.clear()
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
