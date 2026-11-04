import Foundation
import Observation
import UserNotifications

/// Holds the item a tapped notification should open. iOS can deliver the tap
/// before any view exists on a cold launch, so the route waits here until
/// `MainView` is on screen and consumes it.
@MainActor
@Observable
final class NotificationRouter {
    static let shared = NotificationRouter()

    private(set) var pendingReference: LibraryReference?

    func open(_ reference: LibraryReference) {
        pendingReference = reference
    }

    func consume() -> LibraryReference? {
        defer { pendingReference = nil }
        return pendingReference
    }

    /// Notifications from older builds have `item_id` and no `type`. The only
    /// ones written that way were for video transcripts.
    nonisolated static func reference(from userInfo: [AnyHashable: Any]) -> LibraryReference? {
        guard let itemID = userInfo["item_id"] as? String, !itemID.isEmpty else { return nil }
        let itemType = (userInfo["type"] as? String) ?? "transcript"
        guard ["audio", "pdf", "transcript", "youtube"].contains(itemType) else { return nil }
        return LibraryReference(itemType: itemType, itemId: itemID)
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// iOS hides notifications from the foreground app unless asked. The upload
    /// notice stays out of the way here, because the app already shows that state.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        if notification.request.identifier.hasPrefix(NotificationService.uploadIdentifierPrefix) {
            return [.list]
        }
        return [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let reference = NotificationRouter.reference(
                from: response.notification.request.content.userInfo
              )
        else { return }
        await MainActor.run {
            NotificationRouter.shared.open(reference)
        }
    }
}
