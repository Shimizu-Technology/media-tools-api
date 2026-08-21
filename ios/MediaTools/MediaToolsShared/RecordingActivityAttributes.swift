import ActivityKit
import Foundation

/// Data shared by the host app and WidgetKit extension. The start date and
/// semantic content type never change during a recording, while ContentState
/// changes when capture pauses, resumes, or is interrupted. The system renders
/// the timer, so the app does not need to wake every second in the background.
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let elapsedDuration: TimeInterval
        let resumedAt: Date?
        let isPaused: Bool
        let isInterrupted: Bool

        init(
            elapsedDuration: TimeInterval,
            resumedAt: Date?,
            isPaused: Bool,
            isInterrupted: Bool
        ) {
            self.elapsedDuration = elapsedDuration
            self.resumedAt = resumedAt
            self.isPaused = isPaused
            self.isInterrupted = isInterrupted
        }

        private enum CodingKeys: String, CodingKey {
            case elapsedDuration
            case resumedAt
            case isPaused
            case isInterrupted
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            elapsedDuration = try container.decode(TimeInterval.self, forKey: .elapsedDuration)
            resumedAt = try container.decodeIfPresent(Date.self, forKey: .resumedAt)
            // Live Activities created by the previous app build do not contain
            // this field. Treat them as running/interrupted until the host app
            // publishes its first state update after upgrading.
            isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
            isInterrupted = try container.decode(Bool.self, forKey: .isInterrupted)
        }
    }

    let recordingID: UUID
    let startedAt: Date
    let contentType: String

    var contentTypeLabel: String {
        switch contentType {
        case "phone_call": "Conversation"
        case "meeting": "Meeting"
        case "voice_memo": "Voice Memo"
        case "interview": "Interview"
        case "lecture": "Lecture"
        default: "Recording"
        }
    }
}
