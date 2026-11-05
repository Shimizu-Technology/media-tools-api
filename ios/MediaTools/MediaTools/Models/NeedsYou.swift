import Foundation

/// What the Home screen's "Needs you" section offers on a row.
enum NeedsYouAction: Equatable {
    /// One tap sends it. No trip through another screen.
    case transcribe
    /// Save, try again, or delete. Used when sending it unchanged would fail.
    case options
    case open
}

/// Something only the person can move forward. On-device work comes first, because
/// it exists nowhere else.
enum NeedsYouItem: Identifiable {
    case recording(LocalRecording)
    case share(ShareInboxStore.Item)
    case serverFailure(LibraryListItem)

    var id: String {
        switch self {
        case .recording(let recording): "recording:\(recording.id.uuidString)"
        case .share(let item): "share:\(item.id)"
        case .serverFailure(let item): "server:\(item.reference.id)"
        }
    }
}

enum NeedsYouSelection {
    /// Old failures stay in the Library, so this section can empty out and disappear.
    static let serverFailureWindow: TimeInterval = 7 * 24 * 60 * 60

    static func select(
        recordings: [LocalRecording],
        shares: [ShareInboxStore.Item],
        serverFailures: [LibraryListItem],
        autoTranscribeWillSend: Bool,
        now: Date = Date()
    ) -> [NeedsYouItem] {
        let actionable = recordings.filter { $0.needsPerson(autoTranscribeWillSend: autoTranscribeWillSend) }
        let localIDs = Set(recordings.compactMap(\.remoteTranscriptionID))
        let recent = serverFailures.filter { item in
            guard item.status == "failed", !item.archived, let createdAt = item.createdAt else { return false }
            guard now.timeIntervalSince(createdAt) <= serverFailureWindow else { return false }
            // A device copy of the same recording already has a row with more to offer.
            return !(item.itemType == "audio" && localIDs.contains(item.id))
        }
        return actionable.sorted { $0.createdAt > $1.createdAt }.map(NeedsYouItem.recording)
            + shares.map(NeedsYouItem.share)
            + recent.map(NeedsYouItem.serverFailure)
    }
}

extension LocalRecording {
    /// A recording on its way somewhere needs nothing from anyone. One saved under the
    /// automatic setting is only waiting its turn, unless nothing will ever send it.
    func needsPerson(autoTranscribeWillSend: Bool) -> Bool {
        switch state {
        case .invalid, .uploadFailed:
            return true
        case .ready, .interrupted:
            return !(isWaitingForAutomaticTranscription && autoTranscribeWillSend)
        case .recording, .waitingForUpload, .uploading, .finalizingUpload, .serverProcessing:
            return false
        }
    }

    var needsYouAction: NeedsYouAction {
        canUpload ? .transcribe : .options
    }

    /// "Aug 26 recording", or the name of an imported or shared file.
    var needsYouTitle: String {
        if let originalFilename, !originalFilename.isEmpty {
            return (originalFilename as NSString).deletingPathExtension
        }
        return "\(createdAt.formatted(.dateTime.month(.abbreviated).day())) recording"
    }

    /// "1:29:12, not sent yet". A recording that never saved its length says only why
    /// it is here.
    var needsYouDetail: String {
        let reason: String
        switch state {
        case .invalid:
            reason = remoteTranscriptionID == nil ? "did not save fully" : "could not be read"
        case .uploadFailed:
            reason = "upload paused"
        default:
            reason = "not sent yet"
        }
        guard let length = MediaFormat.duration(duration) else {
            return reason.prefix(1).uppercased() + reason.dropFirst()
        }
        return "\(length), \(reason)"
    }
}

/// The time of day Home opens with.
enum HomeGreeting {
    static func text(for date: Date = Date(), calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
    }

    static func dateLine(for date: Date = Date()) -> String {
        date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}
