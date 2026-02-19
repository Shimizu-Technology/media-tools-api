import Foundation

/// App-wide configuration. Values come from the Xcode build settings / Info.plist
/// or fall back to defaults for development.
enum Configuration {
    /// Clerk publishable key — set via CLERK_PUBLISHABLE_KEY in xcconfig or Info.plist.
    static let clerkPublishableKey: String = {
        if let key = Bundle.main.infoDictionary?["CLERK_PUBLISHABLE_KEY"] as? String, !key.isEmpty {
            return key
        }
        // Development fallback — media-tools-api Clerk instance
        return "pk_test_d2VsY29tZWQtZWFyd2lnLTg2LmNsZXJrLmFjY291bnRzLmRldiQ"
    }()

    /// Media Tools API base URL.
    static let apiBaseURL: String = {
        if let url = Bundle.main.infoDictionary?["API_BASE_URL"] as? String, !url.isEmpty {
            return url
        }
        #if DEBUG
        return "http://localhost:8080"
        #else
        return "https://media-tools-api.onrender.com"
        #endif
    }()

    /// Keychain access group shared between the main app and share extension.
    static let keychainAccessGroup = "group.com.shimizu-technology.media-tools"

    /// App Group identifier for sharing data with extensions.
    static let appGroupIdentifier = "group.com.shimizu-technology.media-tools"
}
