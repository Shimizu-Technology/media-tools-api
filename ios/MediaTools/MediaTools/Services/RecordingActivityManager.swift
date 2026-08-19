import ActivityKit
import Foundation

@MainActor
protocol RecordingActivityManaging: AnyObject {
    var areActivitiesEnabled: Bool { get }
    func start(for recording: LocalRecording) async throws
    func update(isInterrupted: Bool, duration: TimeInterval) async
    func end(finalDuration: TimeInterval) async
}

/// Owns the one Live Activity associated with the one microphone capture the
/// app permits at a time. ActivityKit may restore activities after a process
/// relaunch, so every operation consults Activity.activities instead of relying
/// only on an in-memory reference.
@MainActor
final class RecordingActivityManager: RecordingActivityManaging {
    static let shared = RecordingActivityManager()

    var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func start(for recording: LocalRecording) async throws {
        for activity in Activity<RecordingActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        let attributes = RecordingActivityAttributes(
            recordingID: recording.id,
            startedAt: recording.createdAt,
            contentType: recording.contentType
        )
        let state = RecordingActivityAttributes.ContentState(
            elapsedDuration: 0,
            resumedAt: recording.createdAt,
            isInterrupted: false
        )
        _ = try Activity.request(
            attributes: attributes,
            content: ActivityContent(state: state, staleDate: nil),
            pushType: nil
        )
    }

    func update(isInterrupted: Bool, duration: TimeInterval) async {
        let state = RecordingActivityAttributes.ContentState(
            elapsedDuration: duration,
            resumedAt: isInterrupted ? nil : Date(),
            isInterrupted: isInterrupted
        )
        let content = ActivityContent(state: state, staleDate: nil)
        for activity in Activity<RecordingActivityAttributes>.activities {
            await activity.update(content)
        }
    }

    func end(finalDuration: TimeInterval) async {
        let finalState = RecordingActivityAttributes.ContentState(
            elapsedDuration: finalDuration,
            resumedAt: nil,
            isInterrupted: false
        )
        let finalContent = ActivityContent(state: finalState, staleDate: nil)
        for activity in Activity<RecordingActivityAttributes>.activities {
            await activity.end(finalContent, dismissalPolicy: .immediate)
        }
    }
}

enum SystemCaptureOutcome: Equatable {
    case started
    case stopped
    case alreadyStopped
    case microphonePermissionRequired
    case liveActivitiesDisabled
    case failed(String)

    var dialog: String {
        switch self {
        case .started:
            "Recording started. Use the Action Button again or tap Stop on the Live Activity to save it."
        case .stopped:
            "Recording stopped and saved securely on this iPhone."
        case .alreadyStopped:
            "There is no active Media Tools recording."
        case .microphonePermissionRequired:
            "Open Media Tools once and allow microphone access before using Quick Record."
        case .liveActivitiesDisabled:
            "Enable Live Activities for Media Tools in Settings before using Quick Record."
        case .failed(let message):
            "Media Tools could not start recording. \(message)"
        }
    }
}
