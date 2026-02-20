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

    var displayTitle: String {
        title ?? "(Untitled Recording)"
    }

    var isComplete: Bool {
        status == "completed"
    }
}

// MARK: - PDFs

struct PDFExtraction: Identifiable, Codable {
    let id: String
    let filename: String?
    let status: String
    let extractedText: String?
    let pageCount: Int?
    let wordCount: Int?
    let createdAt: Date?

    var displayTitle: String {
        filename ?? "(Untitled PDF)"
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
    let summary: String?
    let keyPoints: [String]?
    let actionItems: [String]?
    let topics: [String]?
    let status: String?
    let message: String? // for async "accepted" responses
}

struct SummaryRequest: Codable {
    let transcriptId: String
    let contentType: String?
    let length: String?
    let style: String?
}

// MARK: - Health

struct HealthResponse: Codable {
    let status: String
    let version: String
    let database: String
    let workers: Int
}
