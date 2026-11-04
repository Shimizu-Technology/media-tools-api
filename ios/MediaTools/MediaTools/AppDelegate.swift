import UIKit
import UserNotifications

/// Bridges background URLSession wake-ups and notification taps into the SwiftUI
/// app lifecycle.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Must be set before launch finishes, or a tap that launched the app
        // is delivered to nobody.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundUploadService.shared.acceptBackgroundEvents(
            identifier: identifier,
            completionHandler: completionHandler
        )
        // A finished share upload may be the first this app has heard of that
        // share. Results are delivered on this queue, so this runs before them.
        if ShareDirectUpload.isShareSession(identifier) {
            MainActor.assumeIsolated {
                RecordingUploadCoordinator.shared.processSharedItems()
            }
        }
    }
}
