import Foundation

/// App-wide configuration. Values come from the Xcode build settings / Info.plist
/// or fall back to defaults for development.
enum Configuration {
    /// Clerk publishable key — set via CLERK_PUBLISHABLE_KEY in xcconfig or Info.plist.
    static let clerkPublishableKey: String = {
        if let key = configuredValue("CLERK_PUBLISHABLE_KEY") {
            return key
        }
        #if DEBUG
        // Development fallback — media-tools-api Clerk instance. Release builds
        // should inject this through xcconfig/Info.plist instead of source.
        return "pk_test_d2VsY29tZWQtZWFyd2lnLTg2LmNsZXJrLmFjY291bnRzLmRldiQ"
        #else
        return ""
        #endif
    }()

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
        return "https://media-tools-gu.netlify.app"
    }()

    /// Keychain access group shared between the main app and share extension.
    static let keychainAccessGroup = "group.com.shimizu-technology.media-tools"

    /// App Group identifier for sharing data with extensions.
    static let appGroupIdentifier = "group.com.shimizu-technology.media-tools"

    private static func configuredValue(_ key: String) -> String? {
        guard let value = Bundle.main.infoDictionary?[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || (trimmed.hasPrefix("$(") && trimmed.hasSuffix(")")) {
            return nil
        }
        return trimmed
    }
}
