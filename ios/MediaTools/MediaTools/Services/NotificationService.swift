import Foundation
import UserNotifications

enum NotificationPermissionState: Equatable {
    case notRequested
    case enabled
    case denied
}

/// Handles local notifications for transcription completion.
/// (Push notifications via APNs can be added later when the backend supports it.)
enum NotificationService {
    static func permissionState() async -> NotificationPermissionState {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .enabled
        case .denied:
            return .denied
        case .notDetermined:
            return .notRequested
        @unknown default:
            return .notRequested
        }
    }

    /// Request notification permissions.
    static func requestPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            print("Notification permission error: \(error)")
            return false
        }
    }

    /// Schedule a local notification when a transcription completes.
    static func notifyTranscriptionComplete(title: String, itemId: String) {
        let content = UNMutableNotificationContent()
        content.title = "Transcription Complete"
        content.body = title
        content.sound = .default
        content.userInfo = ["item_id": itemId]

        let request = UNNotificationRequest(
            identifier: "transcription-\(itemId)",
            content: content,
            trigger: nil // Fire immediately
        )

        UNUserNotificationCenter.current().add(request)
    }

    /// Notify when audio transcription is done.
    static func notifyAudioComplete(title: String, itemId: String) {
        let content = UNMutableNotificationContent()
        content.title = "Audio Transcribed"
        content.body = title
        content.sound = .default
        content.userInfo = ["item_id": itemId, "type": "audio"]

        let request = UNNotificationRequest(
            identifier: "audio-\(itemId)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    static func notifyAudioUploadAccepted(title: String, itemId: String) {
        let content = UNMutableNotificationContent()
        content.title = "Recording Uploaded"
        content.body = "\(title) is ready for transcription."
        content.sound = .default
        content.userInfo = ["item_id": itemId, "type": "audio"]

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "audio-upload-\(itemId)",
                content: content,
                trigger: nil
            )
        )
    }

    static func notifyAudioFailed(title: String, itemId: String) {
        let content = UNMutableNotificationContent()
        content.title = "Transcription Needs Attention"
        content.body = "\(title) could not be transcribed. Open Media Tools to retry."
        content.sound = .default
        content.userInfo = ["item_id": itemId, "type": "audio"]

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "audio-failed-\(itemId)",
                content: content,
                trigger: nil
            )
        )
    }
}
