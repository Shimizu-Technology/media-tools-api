import Foundation
import CoreSpotlight
import MobileCoreServices
import UniformTypeIdentifiers

/// Index transcripts in iOS Spotlight for system-wide search.
enum SpotlightService {
    /// Index lightweight rows from the unified library. This keeps system
    /// search current without downloading every full transcript just to render
    /// the library screen.
    static func indexLibraryItems(_ items: [LibraryListItem]) {
        let searchableItems = items.compactMap { item -> CSSearchableItem? in
            guard item.status == "completed" else { return nil }

            let contentType: UTType = switch item.itemType {
            case "audio": .audio
            case "pdf": .pdf
            default: .text
            }
            let attributes = CSSearchableItemAttributeSet(contentType: contentType)
            attributes.title = item.title
            attributes.contentDescription = item.subtitle
            attributes.keywords = item.tags + [item.itemType, "media tools"]
            if item.itemType == "audio", item.duration > 0 {
                attributes.duration = NSNumber(value: item.duration)
            }

            return CSSearchableItem(
                // Preserve the identifiers used by the earlier per-media
                // indexers so an app update replaces entries instead of
                // leaving duplicate Spotlight results behind.
                uniqueIdentifier: item.itemType == "youtube"
                    ? "transcript-\(item.id)"
                    : "\(item.itemType)-\(item.id)",
                domainIdentifier: "com.shimizu-technology.media-tools.library",
                attributeSet: attributes
            )
        }

        CSSearchableIndex.default().indexSearchableItems(searchableItems)
    }

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
            if let dur = audio.duration {
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
