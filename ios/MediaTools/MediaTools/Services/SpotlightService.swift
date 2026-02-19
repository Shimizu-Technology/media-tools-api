import Foundation
import CoreSpotlight
import MobileCoreServices

/// Index transcripts in iOS Spotlight for system-wide search.
enum SpotlightService {
    /// Index a batch of transcripts for Spotlight search.
    static func indexTranscripts(_ transcripts: [Transcript]) {
        let items = transcripts.compactMap { transcript -> CSSearchableItem? in
            guard transcript.isComplete else { return nil }

            let attributes = CSSearchableItemAttributeSet(contentType: .text)
            attributes.title = transcript.displayTitle
            attributes.contentDescription = String(transcript.transcriptText?.prefix(200) ?? "")
            attributes.keywords = ["transcript", "video", "media tools"]

            return CSSearchableItem(
                uniqueIdentifier: "transcript-\(transcript.id)",
                domainIdentifier: "com.shimizu-technology.media-tools.transcripts",
                attributeSet: attributes
            )
        }

        CSSearchableIndex.default().indexSearchableItems(items) { error in
            if let error {
                print("Spotlight indexing failed: \(error)")
            }
        }
    }

    /// Index audio items.
    static func indexAudioItems(_ items: [AudioTranscription]) {
        let searchableItems = items.compactMap { audio -> CSSearchableItem? in
            guard audio.isComplete else { return nil }

            let attributes = CSSearchableItemAttributeSet(contentType: .audio)
            attributes.title = audio.displayTitle
            attributes.contentDescription = String(audio.transcriptText?.prefix(200) ?? "")
            attributes.keywords = ["audio", "recording", "transcript", "media tools"]
            if let dur = audio.durationSeconds {
                attributes.duration = NSNumber(value: dur)
            }

            return CSSearchableItem(
                uniqueIdentifier: "audio-\(audio.id)",
                domainIdentifier: "com.shimizu-technology.media-tools.audio",
                attributeSet: attributes
            )
        }

        CSSearchableIndex.default().indexSearchableItems(searchableItems)
    }

    /// Remove all indexed items (e.g., on sign-out).
    static func removeAll() {
        CSSearchableIndex.default().deleteAllSearchableItems()
    }
}
