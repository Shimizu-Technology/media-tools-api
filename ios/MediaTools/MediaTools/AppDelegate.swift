import UIKit

/// Bridges background URLSession wake-ups into the SwiftUI app lifecycle.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundUploadService.shared.acceptBackgroundEvents(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }
}
