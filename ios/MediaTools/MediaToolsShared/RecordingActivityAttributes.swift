import ActivityKit
import Foundation

/// Data shared by the host app and WidgetKit extension. The start date and
/// semantic content type never change during a recording, while ContentState
/// only changes for an interruption or resume. The system renders the timer,
/// so the app does not need to wake every second in the background.
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let elapsedDuration: TimeInterval
        let resumedAt: Date?
        let isInterrupted: Bool
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
