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

    func deleteTranscript(_ id: String) async throws {
        try await api.delete("/transcripts/\(id)")
    }

    // MARK: - Audio

    func loadAudioItems() async {
        do {
            let items: [AudioTranscription] = try await api.get("/audio/transcriptions")
            print("📱 Loaded \(items.count) audio items")
            audioItems = items
        } catch {
            print("❌ Failed to load audio: \(error)")
        }
    }

    func getAudioItem(
        _ id: String,
        expectedOwnerID: String? = nil
    ) async throws -> AudioTranscription {
        let item: AudioTranscription = try await api.get(
            "/audio/transcriptions/\(id)",
            expectedOwnerID: expectedOwnerID
        )
        upsertAudioItem(item)
        return item
    }

    func uploadAudio(
        fileURL: URL,
        filename: String,
        mimeType: String,
        contentType: String = "general",
        expectedOwnerID: String? = nil
    ) async throws -> AudioTranscription {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value > 0 else {
            throw APIError.invalidFile(message: "The selected recording is empty.")
        }

        let presign: AudioUploadPresignResponse
        do {
            presign = try await presignAudioUpload(
                filename: filename,
                mimeType: mimeType,
                sizeBytes: size.int64Value,
                expectedOwnerID: expectedOwnerID
            )
        } catch let apiError as APIError where apiError.permitsMultipartUploadFallback {
            // Local and self-hosted environments may intentionally omit S3.
            // Preserve that supported deployment mode with a streaming server
            // upload instead of loading the recording into memory.
            return try await uploadAudioThroughAPI(
                fileURL: fileURL,
                filename: filename,
                mimeType: mimeType,
                contentType: contentType,
                expectedOwnerID: expectedOwnerID
            )
        } catch {
            throw error
        }

        // Once this request begins, never fall back to a second upload path.
        // A lost response can still mean object storage accepted the file, and
        // falling back at that point could create duplicate transcription jobs.
        try await api.putFile(at: fileURL, to: presign.uploadUrl, mimeType: mimeType)

        let completion = AudioUploadCompleteRequest(
            objectKey: presign.objectKey,
            originalName: filename,
            sizeBytes: size.int64Value,
            contentType: contentType
        )
        var completionError: Error?
        for attempt in 0..<3 {
            do {
                let item = try await completeAudioUpload(
                    completion,
                    expectedOwnerID: expectedOwnerID
                )
                return item
            } catch {
                completionError = error
                if let apiError = error as? APIError, !apiError.isRetryable {
                    throw error
                }
                if attempt < 2 {
                    try await Task.sleep(for: .seconds(attempt + 1))
                }
            }
        }
        throw completionError ?? APIError.invalidResponse
    }

    func presignAudioUpload(
        filename: String,
        mimeType: String,
        sizeBytes: Int64,
        expectedOwnerID: String? = nil
    ) async throws -> AudioUploadPresignResponse {
        try await api.post(
            "/audio/uploads/presign",
            body: AudioUploadPresignRequest(
                filename: filename,
                contentType: mimeType,
                sizeBytes: sizeBytes
            ),
            expectedOwnerID: expectedOwnerID
        )
    }

    func completeAudioUpload(
        _ completion: AudioUploadCompleteRequest,
        expectedOwnerID: String? = nil
    ) async throws -> AudioTranscription {
        let item: AudioTranscription = try await api.post(
            "/audio/uploads/complete",
            body: completion,
            expectedOwnerID: expectedOwnerID
        )
        upsertAudioItem(item)
        return item
    }

    func retryAudioItem(_ id: String) async throws -> AudioTranscription {
        let item: AudioTranscription = try await api.post(
            "/audio/transcriptions/\(id)/retry",
            body: EmptyResponse()
        )
        upsertAudioItem(item)
        return item
    }

    func formatAudioTranscript(_ id: String) async throws -> AudioTranscription {
        let item: AudioTranscription = try await api.post(
            "/audio/transcriptions/\(id)/format",
            body: EmptyResponse()
        )
        upsertAudioItem(item)
        return item
    }

    func renameAudioItem(_ id: String, name: String) async throws -> AudioTranscription {
        let item: AudioTranscription = try await api.patch(
            "/audio/transcriptions/\(id)",
            body: RenameAudioRequest(name: name)
        )
        upsertAudioItem(item)
        return item
    }

    func deleteAudioItem(_ id: String) async throws {
        try await api.delete("/audio/transcriptions/\(id)")
    }

    private func uploadAudioThroughAPI(
        fileURL: URL,
        filename: String,
        mimeType: String,
        contentType: String,
        expectedOwnerID: String?
    ) async throws -> AudioTranscription {
        let item: AudioTranscription = try await api.uploadFile(
            "/audio/transcribe",
            fileURL: fileURL,
            filename: filename,
            mimeType: mimeType,
            fields: ["content_type": contentType],
            expectedOwnerID: expectedOwnerID
        )
        upsertAudioItem(item)
        return item
    }

    private func upsertAudioItem(_ item: AudioTranscription) {
        audioItems.removeAll { $0.id == item.id }
        audioItems.insert(item, at: 0)
    }

    // MARK: - PDFs

    func loadPDFs() async {
        do {
            pdfItems = try await api.get("/pdf/extractions")
        } catch {
            print("Failed to load PDFs: \(error)")
        }
    }

    func getPDF(_ id: String) async throws -> PDFExtraction {
        try await api.get("/pdf/extractions/\(id)")
    }

    func getMediaSegments(itemType: String, itemId: String) async throws -> [MediaSegment] {
        try await api.get("/library/items/\(itemType)/\(itemId)/segments")
    }

    func deletePDF(_ id: String) async throws {
        try await api.delete("/pdf/extractions/\(id)")
    }

    // MARK: - Unified Library

    func listLibraryItems(
        page: Int = 1,
        perPage: Int = 20,
        itemType: String? = nil,
        status: String? = nil,
        search: String? = nil,
        sortDirection: String = "desc"
    ) async throws -> LibraryListResponse {
        try await api.get(Self.libraryItemsPath(
            page: page,
            perPage: perPage,
            itemType: itemType,
            status: status,
            search: search,
            sortDirection: sortDirection
        ))
    }

    static func libraryItemsPath(
        page: Int,
        perPage: Int,
        itemType: String?,
        status: String?,
        search: String?,
        sortDirection: String
    ) -> String {
        var components = URLComponents()
        components.path = "/library/items"
        var queryItems = [
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "per_page", value: String(min(max(1, perPage), 100))),
            URLQueryItem(name: "sort_dir", value: sortDirection == "asc" ? "asc" : "desc"),
        ]
        if let itemType, !itemType.isEmpty {
            queryItems.append(URLQueryItem(name: "type", value: itemType))
        }
        if let status, !status.isEmpty {
            queryItems.append(URLQueryItem(name: "status", value: status))
        }
        if let search = search?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
            queryItems.append(URLQueryItem(name: "search", value: search))
        }
        components.queryItems = queryItems
        return components.string ?? "/library/items"
    }

    func getLibraryItem(_ reference: LibraryReference) async throws -> LibraryItem {
        switch reference.itemType {
        case "youtube", "transcript":
            return .transcript(try await getTranscript(reference.itemId))
        case "audio":
            return .audio(try await getAudioItem(reference.itemId))
        case "pdf":
            return .pdf(try await getPDF(reference.itemId))
        default:
            throw APIError.httpError(statusCode: 400, message: "Unknown library item type")
        }
    }

    func deleteLibraryItem(_ reference: LibraryReference) async throws {
        switch reference.itemType {
        case "youtube", "transcript":
            try await deleteTranscript(reference.itemId)
        case "audio":
            try await deleteAudioItem(reference.itemId)
        case "pdf":
            try await deletePDF(reference.itemId)
        default:
            throw APIError.httpError(statusCode: 400, message: "Unknown library item type")
        }
    }

    func getLibraryPreferences(_ reference: LibraryReference) async throws -> LibraryPreferences {
        try await api.get(
            "/library/items/\(reference.collectionItemType)/\(reference.itemId)/preferences"
        )
    }

    func updateLibraryPreferences(
        _ reference: LibraryReference,
        updates: UpdateLibraryPreferencesRequest
    ) async throws -> LibraryPreferences {
        try await api.patch(
            "/library/items/\(reference.collectionItemType)/\(reference.itemId)/preferences",
            body: updates
        )
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

    func getSummaries(transcriptId: String) async throws -> [Summary] {
        try await api.get("/transcripts/\(transcriptId)/summaries")
    }

    func getSummary(transcriptId: String, contentType: String? = nil) async throws -> Summary {
        let _: EmptyResponse = try await api.post("/summaries", body: SummaryRequest(
            transcriptId: transcriptId,
            contentType: contentType,
            length: "medium",
            style: "bullet"
        ))

        return try await pollTranscriptSummary(transcriptId: transcriptId)
    }

    func summarizeAudio(audioId: String, contentType: String? = nil) async throws -> Summary {
        let accepted: AudioTranscription = try await api.post(
            "/audio/transcriptions/\(audioId)/summarize",
            body: SummarizeAudioRequest(contentType: contentType, model: nil, length: "medium")
        )
        if accepted.summaryStatus == "completed" {
            return audioSummary(from: accepted)
        }

        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let audio = try await getAudioItem(audioId)
            if audio.summaryStatus == "failed" {
                throw APIError.httpError(
                    statusCode: 500,
                    message: audio.summaryErrorMessage ?? "Summary generation failed"
                )
            }
            if audio.summaryStatus == "completed" {
                return audioSummary(from: audio)
            }
        }
        throw APIError.httpError(statusCode: 408, message: "Summary generation timed out")
    }

    private func audioSummary(from audio: AudioTranscription) -> Summary {
        Summary(
            id: audio.id,
            transcriptId: nil,
            summaryText: audio.summaryText,
            keyPoints: audio.keyPoints,
            actionItems: audio.actionItems,
            topics: nil,
            status: audio.summaryStatus,
            message: nil,
            errorMessage: audio.summaryErrorMessage,
            evidence: audio.summaryEvidence
        )
    }

    private func pollTranscriptSummary(transcriptId: String) async throws -> Summary {
        for _ in 0..<30 {
            let summaries = try await getSummaries(transcriptId: transcriptId)
            if let latest = summaries.first {
                if latest.isFailed {
                    throw APIError.httpError(statusCode: 500, message: latest.failureMessage)
                }
                if latest.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    return latest
                }
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw APIError.httpError(statusCode: 408, message: "Summary generation timed out")
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

        // Index in Spotlight for system-wide search
        SpotlightService.indexTranscripts(transcripts)
        SpotlightService.indexAudioItems(audioItems)

    }
}
