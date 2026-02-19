import Foundation

/// High-level service wrapping APIClient for domain-specific operations.
@Observable
final class MediaToolsService {
    static let shared = MediaToolsService()

    private(set) var transcripts: [Transcript] = []
    private(set) var audioItems: [AudioTranscription] = []
    private(set) var pdfItems: [PDFExtraction] = []
    private(set) var collections: [Collection] = []
    private(set) var isLoading = false

    private let api = APIClient.shared

    // MARK: - Transcripts

    func loadTranscripts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response: TranscriptListResponse = try await api.get("/transcripts")
            transcripts = response.data
        } catch {
            print("Failed to load transcripts: \(error)")
        }
    }

    func getTranscript(_ id: String) async throws -> Transcript {
        try await api.get("/transcripts/\(id)")
    }

    func transcribeURL(_ url: String) async throws -> Transcript {
        try await api.post("/transcripts", body: TranscribeRequest(url: url))
    }

    func searchTranscripts(_ query: String) async throws -> [Transcript] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let response: TranscriptListResponse = try await api.get("/transcripts?search=\(encoded)")
        return response.data
    }

    // MARK: - Audio

    func loadAudioItems() async {
        do {
            audioItems = try await api.get("/audio/transcriptions")
        } catch {
            print("Failed to load audio: \(error)")
        }
    }

    func getAudioItem(_ id: String) async throws -> AudioTranscription {
        try await api.get("/audio/transcriptions/\(id)")
    }

    func uploadAudio(data: Data, filename: String, contentType: String = "general") async throws -> AudioTranscription {
        try await api.upload(
            "/audio/transcriptions",
            fileData: data,
            filename: filename,
            mimeType: "audio/m4a",
            fields: ["content_type": contentType]
        )
    }

    // MARK: - PDFs

    func loadPDFs() async {
        do {
            pdfItems = try await api.get("/pdf/extractions")
        } catch {
            print("Failed to load PDFs: \(error)")
        }
    }

    // MARK: - Collections

    func loadCollections() async {
        do {
            collections = try await api.get("/collections")
        } catch {
            print("Failed to load collections: \(error)")
        }
    }

    func getCollection(_ id: String) async throws -> Collection {
        try await api.get("/collections/\(id)")
    }

    func createCollection(name: String, description: String? = nil) async throws -> Collection {
        try await api.post("/collections", body: CreateCollectionRequest(name: name, description: description))
    }

    func addToCollection(_ collectionId: String, itemType: String, itemId: String) async throws {
        let body = AddItemsRequest(items: [AddItemEntry(itemType: itemType, itemId: itemId)])
        try await api.post("/collections/\(collectionId)/items", body: body) as Void
    }

    func deleteCollection(_ id: String) async throws {
        try await api.delete("/collections/\(id)")
    }

    // MARK: - Chat

    func chat(itemType: String, itemId: String, message: String) async throws -> ChatResponse {
        let path: String
        switch itemType {
        case "transcript":
            path = "/transcripts/\(itemId)/chat"
        case "audio":
            path = "/audio/transcriptions/\(itemId)/chat"
        case "pdf":
            path = "/pdf/extractions/\(itemId)/chat"
        case "collection":
            path = "/collections/\(itemId)/chat"
        default:
            throw APIError.httpError(statusCode: 400, message: "Unknown item type: \(itemType)")
        }
        return try await api.post(path, body: ChatRequest(message: message))
    }

    func getChatHistory(itemType: String, itemId: String) async throws -> ChatResponse {
        let path: String
        switch itemType {
        case "transcript":
            path = "/transcripts/\(itemId)/chat"
        case "audio":
            path = "/audio/transcriptions/\(itemId)/chat"
        case "pdf":
            path = "/pdf/extractions/\(itemId)/chat"
        case "collection":
            path = "/collections/\(itemId)/chat"
        default:
            throw APIError.httpError(statusCode: 400, message: "Unknown item type")
        }
        return try await api.get(path)
    }

    // MARK: - Summary

    func getSummary(transcriptId: String, contentType: String? = nil) async throws -> Summary {
        try await api.post("/summaries", body: SummaryRequest(
            transcriptId: transcriptId,
            contentType: contentType,
            length: "medium",
            style: "bullet"
        ))
    }

    // MARK: - Refresh All

    func refreshAll() async {
        isLoading = true
        defer { isLoading = false }
        async let t: () = loadTranscripts()
        async let a: () = loadAudioItems()
        async let p: () = loadPDFs()
        async let c: () = loadCollections()
        _ = await (t, a, p, c)
    }
}
