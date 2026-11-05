import Foundation

/// App-wide configuration. Values come from the Xcode build settings / Info.plist
/// or fall back to defaults for development.
enum Configuration {
    /// Media Tools API base URL.
    static let apiBaseURL: String = {
        if let url = configuredValue("API_BASE_URL") {
            return url
        }
        // Point to production Render API (localhost won't work on device)
        return "https://media-tools-api.onrender.com"
    }()

    /// Browser app used as a deep-link fallback for cross-item citations.
    static let webAppURL: String = {
        if let url = configuredValue("WEB_APP_URL") {
            return url
        }
        return "https://media.shimizu-technology.com"
    }()

    /// App Group shared with the share extension. It doubles as the Keychain
    /// access group for the capture key: iOS treats every App Group an app belongs
    /// to as an access group. Adding a `keychain-access-groups` entitlement instead
    /// would make its first entry the default for new items, and the device session
    /// is saved with no explicit group, so it would land where the extension can read.
    static let appGroupIdentifier = ShareDirectUpload.appGroupIdentifier

    static let privacyURL = URL(string: "\(webAppURL)/privacy")!
    static let termsURL = URL(string: "\(webAppURL)/terms")!
    static let supportURL = URL(string: "\(webAppURL)/support")!
    static let accountDeletionURL = URL(string: "\(webAppURL)/delete-account")!
    static let developerURL = URL(string: "\(webAppURL)/app/settings/developer")!

    private static func configuredValue(_ key: String) -> String? {
        guard let value = Bundle.main.infoDictionary?[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || (trimmed.hasPrefix("$(") && trimmed.hasSuffix(")")) {
            return nil
        }
        return trimmed
    }
}
