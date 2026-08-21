import Foundation

// MARK: - Transcripts (Videos)

struct Transcript: Identifiable, Codable {
    let id: String
    let title: String?
    let youtubeUrl: String?
    let status: String
    let transcriptText: String?
    let wordCount: Int?
    let createdAt: Date?
    let updatedAt: Date?

    var displayTitle: String {
        title ?? "(Untitled)"
    }

    var isComplete: Bool {
        status == "completed"
    }
}

struct TranscriptListResponse: Codable {
    let data: [Transcript]
    let total: Int?
    let page: Int?
    let perPage: Int?
}

struct TranscribeRequest: Codable {
    let url: String
}

// MARK: - Audio

struct AudioTranscription: Identifiable, Codable {
    let id: String
    let title: String?
    let status: String
    let transcriptText: String?
    let formattedTranscriptText: String?
    let formattingStatus: String?
    let formattingModel: String?
    let formattingVersion: String?
    let formattingErrorMessage: String?
    let contentType: String?
    let duration: Double?
    let wordCount: Int?
    let createdAt: Date?
    let filename: String?
    let originalName: String?
    let errorMessage: String?
    let processingStage: String?
    let processingProgress: Int?
    let qualityWarning: String?
    let summaryText: String?
    let keyPoints: [String]?
    let actionItems: [String]?
    let decisions: [String]?
    let summaryLength: String?
    let summaryStatus: String?
    let summaryEvidence: SummaryEvidence?
    let summaryErrorMessage: String?

    var displayTitle: String {
        title ?? originalName ?? filename ?? "(Untitled Recording)"
    }

    var isComplete: Bool {
        status == "completed"
    }

    var isRetryable: Bool {
        processingStage != "invalid_source"
    }

    var readableTranscriptText: String? {
        guard formattingStatus == "completed",
              let formattedTranscriptText,
              !formattedTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return transcriptText }
        return formattedTranscriptText
    }

    /// The original view is useful only when readability formatting produced a
    /// visibly different result. Both values remain stored for exports and
    /// provenance even when the UI collapses the duplicate choice.
    var hasDistinctReadableTranscript: Bool {
        guard formattingStatus == "completed",
              let transcriptText,
              let formattedTranscriptText
        else { return false }

        let original = Self.normalizedTranscriptForDisplayComparison(transcriptText)
        let readable = Self.normalizedTranscriptForDisplayComparison(formattedTranscriptText)
        return !original.isEmpty && !readable.isEmpty && original != readable
    }

    var processingDescription: String {
        switch processingStage {
        case "queued": "Waiting to start"
        case "preparing", "normalizing": "Preparing audio"
        case "splitting": "Splitting long recording"
        case "transcribing": "Transcribing audio"
        case "stitching", "finalizing": "Finalizing transcript"
        case "invalid_source": "Recording file needs recovery"
        default: status == "pending" ? "Waiting to start" : "Processing transcription"
        }
    }

    private static func normalizedTranscriptForDisplayComparison(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct AudioUploadPresignRequest: Codable {
    let filename: String
    let contentType: String
    let sizeBytes: Int64
}

struct AudioUploadPresignResponse: Codable {
    let uploadUrl: URL
    let objectKey: String
    let storedName: String
    let uploadId: String
    let expiresIn: String
}

struct AudioUploadCompleteRequest: Codable {
    let objectKey: String
    let originalName: String
    let sizeBytes: Int64
    let contentType: String
}

struct RenameAudioRequest: Codable {
    let name: String
}

// MARK: - PDFs

struct PDFExtraction: Identifiable, Codable {
    let id: String
    let filename: String?
    let originalName: String?
    let status: String
    let textContent: String?
    let pageCount: Int?
    let wordCount: Int?
    let createdAt: Date?
    let errorMessage: String?

    var displayTitle: String {
        originalName ?? filename ?? "(Untitled PDF)"
    }
}

// MARK: - Unified Library

/// Lightweight metadata returned by the paginated library endpoint. Keeping
/// list rows separate from full transcript/PDF payloads makes search and
/// pagination fast even when the underlying content is large.
struct LibraryListItem: Identifiable, Codable, Hashable {
    let id: String
    let itemType: String
    let title: String
    let subtitle: String
    let status: String
    let wordCount: Int
    let duration: Double
    let pageCount: Int
    let summaryStatus: String
    let favorite: Bool
    let archived: Bool
    let tags: [String]
    let createdAt: Date?

    var reference: LibraryReference {
        LibraryReference(itemType: itemType, itemId: id)
    }

    var displayTitle: String {
        let supportedExtensions: Set<String>
        switch itemType {
        case "audio":
            supportedExtensions = ["aac", "caf", "m4a", "mp3", "mp4", "mov", "wav"]
        case "pdf":
            supportedExtensions = ["pdf"]
        default:
            supportedExtensions = []
        }

        let pathExtension = (title as NSString).pathExtension.lowercased()
        guard supportedExtensions.contains(pathExtension) else { return title }
        let titleWithoutExtension = (title as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return titleWithoutExtension.isEmpty ? title : titleWithoutExtension
    }

    var displaySubtitle: String? {
        let value = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if itemType == "audio" {
            let normalized = value.lowercased()
            let languageCodes: Set<String> = [
                "en", "en-us", "en-gb", "es", "fr", "de", "it", "ja", "ko", "pt", "zh",
            ]
            if normalized == "recording" || languageCodes.contains(normalized) {
                return nil
            }
        }
        return value
    }

    var createdDateText: String? {
        createdAt?.formatted(
            .dateTime
                .month(.abbreviated)
                .day()
                .hour()
                .minute()
        )
    }
}

struct LibraryListResponse: Codable {
    let data: [LibraryListItem]
    let page: Int
    let perPage: Int
    let totalItems: Int
    let totalPages: Int
}

/// IDs are only unique inside their media table, so every selection and
/// navigation destination carries the type as part of its identity.
struct LibraryReference: Identifiable, Codable, Hashable {
    let itemType: String
    let itemId: String

    var id: String { "\(itemType):\(itemId)" }

    var collectionItemType: String {
        itemType == "youtube" ? "transcript" : itemType
    }
}

struct LibraryPreferences: Codable, Equatable {
    let favorite: Bool
    let archived: Bool
    let tags: [String]
}

/// Optional fields preserve PATCH semantics: omitted values stay unchanged on
/// the server while an explicitly supplied empty tags array clears all tags.
struct UpdateLibraryPreferencesRequest: Encodable {
    let favorite: Bool?
    let archived: Bool?
    let tags: [String]?

    init(favorite: Bool? = nil, archived: Bool? = nil, tags: [String]? = nil) {
        self.favorite = favorite
        self.archived = archived
        self.tags = tags
    }
}

// MARK: - Collections

struct Collection: Identifiable, Codable {
    let id: String
    let name: String
    let description: String?
    let itemCount: Int?
    let items: [CollectionItem]?
    let createdAt: Date?
}

struct CollectionItem: Identifiable, Codable {
    let id: String
    let itemType: String
    let itemId: String
    let itemTitle: String?
    let itemStatus: String?
}

struct CreateCollectionRequest: Codable {
    let name: String
    let description: String?
}

struct AddItemsRequest: Codable {
    let items: [AddItemEntry]
}

struct AddItemEntry: Codable {
    let itemType: String
    let itemId: String
}

// MARK: - Chat

struct ChatMessage: Identifiable, Codable {
    let id: String?
    let role: String
    let content: String
    let citations: [Citation]?

    // Synthesized id for SwiftUI lists
    var stableId: String {
        id ?? UUID().uuidString
    }
}

struct ChatRequest: Codable {
    let message: String
}

struct ChatResponse: Codable {
    let messages: [ChatMessage]
}

// MARK: - Summary

struct Summary: Codable {
    let id: String?
    let transcriptId: String?
    let summaryText: String?
    let keyPoints: [String]?
    let actionItems: [String]?
    let topics: [String]?
    let status: String?
    let message: String? // for async "accepted" responses
    let errorMessage: String?
    let evidence: SummaryEvidence?

    var summary: String? { summaryText }

    var isFailed: Bool {
        guard let status else { return false }
        return ["failed", "error"].contains(status.lowercased())
    }

    var failureMessage: String {
        errorMessage ?? message ?? "Summary generation failed"
    }
}

// MARK: - Source Evidence

struct Citation: Codable, Hashable {
    let segmentId: String
    let itemType: String
    let itemId: String
    let itemTitle: String?
    let startMs: Int64?
    let endMs: Int64?
    let pageNumber: Int?

    var locatorLabel: String {
        if let pageNumber {
            return "Page \(pageNumber)"
        }
        if let startMs {
            return Self.formatTime(startMs)
        }
        return "Source"
    }

    static func formatTime(_ milliseconds: Int64) -> String {
        let totalSeconds = max(0, milliseconds / 1_000)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%lld:%02lld:%02lld", hours, minutes, seconds)
        }
        return String(format: "%lld:%02lld", minutes, seconds)
    }
}

struct SummaryEvidence: Codable {
    let summary: [Citation]?
    let keyPoints: [[Citation]]?
    let actionItems: [[Citation]]?
    let decisions: [[Citation]]?
    let topics: [[Citation]]?
}

struct MediaSegment: Identifiable, Codable {
    let id: String
    let itemType: String
    let itemId: String
    let ordinal: Int
    let startMs: Int64?
    let endMs: Int64?
    let pageNumber: Int?
    let text: String
    let createdAt: Date?

    var locatorLabel: String {
        if let pageNumber {
            return "Page \(pageNumber)"
        }
        if let startMs {
            return Citation.formatTime(startMs)
        }
        return "Source"
    }
}

struct SummaryRequest: Codable {
    let transcriptId: String
    let contentType: String?
    let length: String?
    let style: String?
}

struct SummarizeAudioRequest: Codable {
    let contentType: String?
    let model: String?
    let length: String?
}

struct EmptyResponse: Codable {}

// MARK: - Health

struct HealthResponse: Codable {
    let status: String
    let version: String
    let database: String
    let workers: Int
}
