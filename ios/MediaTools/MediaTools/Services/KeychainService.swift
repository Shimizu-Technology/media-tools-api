import Foundation
import Security

/// Shared Keychain storage for auth tokens.
/// Used by both the main app and the Share Extension.
enum KeychainService {
    private static let service = "com.shimizu-technology.media-tools.auth"
    private static let accessGroup = Configuration.keychainAccessGroup
    private static let tokenKey = "clerk-session-token"

    /// Save the Clerk session token to shared Keychain.
    static func saveToken(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }

        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenKey,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenKey,
            kSecAttrAccessGroup as String: accessGroup,
            kSecValueData as String: data,
            // The share extension still needs access after the first unlock,
            // but a session token should never migrate through device backups.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    /// Read the Clerk session token from shared Keychain.
    static func readToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenKey,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Delete the stored token (on sign-out).
    static func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenKey,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
