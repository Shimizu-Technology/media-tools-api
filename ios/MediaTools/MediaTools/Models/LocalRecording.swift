import Foundation

/// The durable, device-local state of a recording before the server accepts it.
///
/// Recording first and uploading second keeps capture independent from sign-in,
/// connectivity, and API availability. Later quick-capture intents use this same
/// model, so a lock-screen recording follows the exact same recovery path as a
/// recording started in the app.
enum LocalRecordingState: String, Codable, Sendable {
    case recording
    case ready
    case interrupted
    case waitingForUpload
    case uploading
    case finalizingUpload
    case uploadFailed
}

struct LocalRecording: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let filename: String
    let originalFilename: String?
    let createdAt: Date
    var duration: TimeInterval
    let contentType: String
    var state: LocalRecordingState
    var lastError: String?
    var uploadProgress: Double?
    var uploadObjectKey: String?
    var uploadSizeBytes: Int64?
    var uploadMimeType: String?
    var uploadTaskIdentifier: Int?

    var displayTitle: String {
        if let originalFilename, !originalFilename.isEmpty {
            return (originalFilename as NSString).deletingPathExtension
        }
        return Self.titleFormatter.string(from: createdAt)
    }

    var uploadFilename: String {
        originalFilename ?? filename
    }

    var formattedDuration: String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var recoveryDescription: String {
        switch state {
        case .recording:
            return "Recording"
        case .ready:
            return "Saved on this iPhone"
        case .interrupted:
            return "Recovered after an interruption"
        case .waitingForUpload:
            return "Waiting for a connection"
        case .uploading:
            let percent = Int(((uploadProgress ?? 0) * 100).rounded())
            return percent > 0 ? "Uploading \(percent)%" : "Starting upload"
        case .finalizingUpload:
            return "Finishing securely"
        case .uploadFailed:
            return lastError ?? "Upload paused"
        }
    }

    var isUploadInProgress: Bool {
        state == .waitingForUpload || state == .uploading || state == .finalizingUpload
    }

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
