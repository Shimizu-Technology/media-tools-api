import Security
import XCTest
@testable import MediaTools

/// These use the real Keychain, so they need a signed build. CI builds unsigned and
/// skips them; run with ad-hoc signing to exercise them.
@MainActor
final class KeychainIsolationTests: XCTestCase {
    private let sessionService = "com.shimizu-technology.media-tools.device-session"
    private var account = ""

    override func setUp() async throws {
        account = "test-\(UUID().uuidString)"
    }

    private func requireKeychain() throws {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.shimizu-technology.media-tools.keychain-probe",
            kSecAttrAccessGroup as String: ShareDirectUpload.appGroupIdentifier,
        ]
        if SecItemCopyMatching(probe as CFDictionary, nil) == errSecMissingEntitlement {
            throw XCTSkip("This build has no Keychain entitlement")
        }
    }

    func testASessionBuild13WroteLoadsThroughTheRealStore() throws {
        try requireKeychain()
        let json = """
        {"pair":{"session_id":"s","user_id":"server-a","access_token":"a","access_expires_at":700000000,\
        "refresh_token":"r","inactive_expires_at":900000000},"source":"clerk","verifiedClerkID":"user_2abc"}
        """
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sessionService,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(json.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        XCTAssertEqual(SecItemAdd(attributes as CFDictionary, nil), errSecSuccess)
        let store = DeviceSessionKeychainStore(account: account)
        addTeardownBlock { [account, sessionService] in
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: sessionService,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
        }

        guard case .found(let session) = store.loadResult() else {
            return XCTFail("A stored session must never read as signed out")
        }
        XCTAssertEqual(session.source, .clerk)
        XCTAssertEqual(session.verifiedClerkID, "user_2abc")
        XCTAssertEqual(session.pair.userID, "server-a")
    }

    /// The account, service, and format build 13's store actually used.
    func testAJournalBuild13WroteLoadsThroughTheRealStore() throws {
        try requireKeychain()
        let journalAccount = "first-party-ios-bootstrap-v1"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sessionService,
            kSecAttrAccount as String: journalAccount,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(#"{"verifiedClerkID":"user_2abc","nextRefreshToken":"mta_rt_x"}"#.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        XCTAssertEqual(SecItemAdd(attributes as CFDictionary, nil), errSecSuccess)
        addTeardownBlock { SecItemDelete(query as CFDictionary) }

        let store = DeviceSessionKeychainStore(account: account)
        guard case .found(var journal) = store.loadPendingBootstrap() else {
            return XCTFail("A journal holding a live credential must not read as missing")
        }
        XCTAssertEqual(journal.verifiedClerkID, "user_2abc")
        XCTAssertEqual(journal.nextRefreshToken, "mta_rt_x")
        XCTAssertNil(journal.recoverySuccessorToken)

        journal.recoverySuccessorToken = "mta_rt_y"
        try store.savePendingBootstrap(journal)
        XCTAssertEqual(store.loadPendingBootstrap(), .found(journal))

        store.delete()
        XCTAssertEqual(store.loadPendingBootstrap(), .missing)
    }

    /// The whole reason not to add a `keychain-access-groups` entitlement.
    func testTheDeviceSessionIsNotReadableFromTheSharedGroup() throws {
        try requireKeychain()
        let store = DeviceSessionKeychainStore(account: account)
        addTeardownBlock { [store] in await MainActor.run { store.delete() } }
        try store.save(StoredDeviceSession(
            pair: DeviceSessionPair(
                sessionID: "s", userID: "server-a", accessToken: "a",
                accessExpiresAt: .distantFuture, refreshToken: "r", inactiveExpiresAt: .distantFuture
            ),
            source: .passkey
        ))

        let shared: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sessionService,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: ShareDirectUpload.appGroupIdentifier,
        ]
        XCTAssertEqual(SecItemCopyMatching(shared as CFDictionary, nil), errSecItemNotFound)
        guard case .found = store.loadResult() else {
            return XCTFail("The app must still read its own session")
        }
    }

    func testTheCaptureKeyIsDeletedOnlyByItsOwnID() throws {
        try requireKeychain()
        let store = ShareUploadKeychainStore(account: account)
        addTeardownBlock { store.delete() }
        let old = ShareUploadCredential(keyID: "old", rawKey: "raw", ownerID: "server-a")
        let replacement = ShareUploadCredential(keyID: "new", rawKey: "raw2", ownerID: "server-a")
        try store.save(old)
        try store.save(replacement)

        store.delete(ifKeyID: "old")
        XCTAssertEqual(store.load(), .found(replacement), "A late rejection of the old key leaves the new one")

        store.delete(ifKeyID: "new")
        XCTAssertEqual(store.load(), .missing)
    }

    func testTheCaptureKeyLivesInTheSharedGroup() throws {
        try requireKeychain()
        let store = ShareUploadKeychainStore(account: account)
        addTeardownBlock { store.delete() }
        XCTAssertEqual(store.load(), .missing)

        let credential = ShareUploadCredential(keyID: "k", rawKey: "raw", ownerID: "server-a")
        try store.save(credential)
        XCTAssertEqual(store.load(), .found(credential))

        let replaced = ShareUploadCredential(keyID: "k2", rawKey: "raw2", ownerID: "server-a")
        try store.save(replaced)
        XCTAssertEqual(store.load(), .found(replaced))

        store.delete()
        XCTAssertEqual(store.load(), .missing)
    }
}
