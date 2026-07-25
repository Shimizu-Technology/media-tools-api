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
    let contentType: String?
    let duration: Double?
    let wordCount: Int?
    let createdAt: Date?
    let filename: String?
    let originalName: String?
    let errorMessage: String?
    let summaryText: String?
    let keyPoints: [String]?
    let actionItems: [String]?
    let decisions: [String]?
    let summaryStatus: String?
    let summaryEvidence: SummaryEvidence?
    let summaryErrorMessage: String?

    var displayTitle: String {
        title ?? originalName ?? filename ?? "(Untitled Recording)"
    }

    var isComplete: Bool {
        status == "completed"
    }
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
