import Foundation

/// Shared constants between iOS app and watchOS app for WatchConnectivity messages.
enum WatchMessage {
    // MARK: - Message Keys
    static let typeKey = "type"
    static let statusKey = "status"
    static let titleKey = "title"
    static let idKey = "id"
    static let wordCountKey = "wordCount"
    static let errorKey = "error"
    static let timestampKey = "timestamp"
    static let contentTypeKey = "contentType"

    // MARK: - Message Types (Watch → iPhone)
    static let audioRecorded = "audioRecorded"
    static let requestStatus = "requestStatus"

    // MARK: - Message Types (iPhone → Watch)
    static let transcriptionUpdate = "transcriptionUpdate"
    static let transcriptionComplete = "transcriptionComplete"
    static let transcriptionFailed = "transcriptionFailed"
    static let recentItems = "recentItems"

    // MARK: - File Transfer Metadata Keys
    static let filenameKey = "filename"
    static let durationKey = "duration"
    static let recordedAtKey = "recordedAt"

    // MARK: - Transcription Statuses
    static let statusPending = "pending"
    static let statusProcessing = "processing"
    static let statusCompleted = "completed"
    static let statusFailed = "failed"
}
