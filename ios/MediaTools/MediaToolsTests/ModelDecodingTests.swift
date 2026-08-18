import XCTest
@testable import MediaTools

final class ModelDecodingTests: XCTestCase {
    private struct DatedPayload: Decodable {
        let createdAt: Date
    }

    func testHealthResponseDecodesHealthyDatabaseState() throws {
        let data = Data(#"{"status":"ok","version":"1.0.0","database":"healthy","workers":3,"yt_dlp_cookies_configured":true}"#.utf8)
        let health = try JSONDecoder().decode(HealthResponse.self, from: data)

        XCTAssertEqual(health.status, "ok")
        XCTAssertEqual(health.database, "healthy")
        XCTAssertEqual(health.workers, 3)
    }

    func testAPIDecoderAcceptsGoDatesWithAndWithoutFractionalSeconds() throws {
        let fractional = Data(#"{"created_at":"2026-02-20T00:33:45.123Z"}"#.utf8)
        let whole = Data(#"{"created_at":"2026-02-20T00:33:45Z"}"#.utf8)
        let decoder = APIClient.makeDecoder()

        let fractionalPayload = try decoder.decode(DatedPayload.self, from: fractional)
        let wholePayload = try decoder.decode(DatedPayload.self, from: whole)

        XCTAssertEqual(
            fractionalPayload.createdAt.timeIntervalSince(wholePayload.createdAt),
            0.123,
            accuracy: 0.001
        )
    }

    func testHostApplicationHasInstallableBundleMetadata() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.ShimizuTechnology.MediaTools")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundlePackageType") as? String, "APPL")
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable"))
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion"))
    }

    func testAudioProcessingStateDecodesIntoUsefulProgressCopy() throws {
        let data = Data(
            #"{"id":"audio-1","status":"processing","processing_stage":"splitting","processing_progress":35}"#
                .utf8)
        let item = try APIClient.makeDecoder().decode(AudioTranscription.self, from: data)

        XCTAssertEqual(item.processingStage, "splitting")
        XCTAssertEqual(item.processingProgress, 35)
        XCTAssertEqual(item.processingDescription, "Splitting long recording")
    }

    func testAudioUploadCompletionEncodesSemanticContentType() throws {
        let request = AudioUploadCompleteRequest(
            objectKey: "audio/user/upload.m4a",
            originalName: "Team sync.m4a",
            sizeBytes: 42,
            contentType: "meeting"
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any]
        )

        XCTAssertEqual(object["object_key"] as? String, "audio/user/upload.m4a")
        XCTAssertEqual(object["content_type"] as? String, "meeting")
        XCTAssertEqual(object["size_bytes"] as? Int, 42)
    }

    func testMultipartAudioBodyStreamsFileAndSanitizesFilename() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source.m4a")
        let destination = directory.appendingPathComponent("body.upload")
        let sourceBytes = Data([0x00, 0x01, 0x7F, 0xFF])
        try sourceBytes.write(to: source)

        try APIClient.writeMultipartBody(
            to: destination,
            sourceURL: source,
            filename: "memo\"\r\n.m4a",
            mimeType: "audio/mp4",
            fields: ["content_type": "voice_memo"],
            boundary: "test-boundary"
        )

        let body = try Data(contentsOf: destination)
        let header = try XCTUnwrap(String(data: body, encoding: .isoLatin1))
        XCTAssertTrue(header.contains("name=\"content_type\"\r\n\r\nvoice_memo"))
        XCTAssertTrue(header.contains("filename=\"memo.m4a\""))
        XCTAssertFalse(header.contains("memo\""))
        XCTAssertNotNil(body.range(of: sourceBytes))
        XCTAssertTrue(header.hasSuffix("\r\n--test-boundary--\r\n"))
    }

    func testAPIErrorsOnlyRetryTransientFailures() {
        XCTAssertTrue(APIError.invalidResponse.isRetryable)
        XCTAssertTrue(APIError.httpError(statusCode: 429, message: "Busy").isRetryable)
        XCTAssertTrue(APIError.httpError(statusCode: 503, message: "Unavailable").isRetryable)
        XCTAssertFalse(APIError.httpError(statusCode: 400, message: "Invalid").isRetryable)
        XCTAssertFalse(APIError.invalidFile(message: "Empty").isRetryable)
    }

    func testMultipartFallbackOnlyHandlesUnavailablePresigning() {
        XCTAssertTrue(
            APIError.httpError(statusCode: 503, code: "storage_unavailable", message: "No storage")
                .permitsMultipartUploadFallback
        )
        XCTAssertTrue(
            APIError.httpError(statusCode: 404, message: "Unknown endpoint")
                .permitsMultipartUploadFallback
        )
        XCTAssertFalse(
            APIError.httpError(statusCode: 401, code: "unauthorized", message: "Sign in")
                .permitsMultipartUploadFallback
        )
        XCTAssertFalse(
            APIError.httpError(statusCode: 429, code: "rate_limited", message: "Slow down")
                .permitsMultipartUploadFallback
        )
    }

    func testUnifiedLibraryResponseDecodesTypedMetadataAndPagination() throws {
        let data = Data(
            #"{"data":[{"id":"shared-id","item_type":"audio","title":"Team sync","subtitle":"EN","status":"processing","word_count":0,"duration":42.5,"page_count":0,"summary_status":"","favorite":true,"archived":false,"tags":["meeting"],"created_at":"2026-08-18T01:02:03Z"}],"page":2,"per_page":20,"total_items":41,"total_pages":3}"#
                .utf8)

        let response = try APIClient.makeDecoder().decode(LibraryListResponse.self, from: data)

        XCTAssertEqual(response.page, 2)
        XCTAssertEqual(response.totalItems, 41)
        XCTAssertEqual(response.totalPages, 3)
        XCTAssertEqual(response.data.first?.reference.id, "audio:shared-id")
        XCTAssertEqual(response.data.first?.tags, ["meeting"])
        XCTAssertEqual(response.data.first?.favorite, true)
    }

    func testLibraryReferencesIncludeTypeInIdentity() {
        let transcript = LibraryReference(itemType: "youtube", itemId: "shared-id")
        let audio = LibraryReference(itemType: "audio", itemId: "shared-id")

        XCTAssertNotEqual(transcript, audio)
        XCTAssertEqual(Set([transcript, audio]).count, 2)
        XCTAssertEqual(transcript.collectionItemType, "transcript")
        XCTAssertEqual(audio.collectionItemType, "audio")
    }

    func testSpotlightIdentifiersMatchLegacyAndUnifiedMediaPrefixes() {
        XCTAssertEqual(
            SpotlightService.libraryIdentifier(
                for: LibraryReference(itemType: "youtube", itemId: "video-id")
            ),
            "transcript-video-id"
        )
        XCTAssertEqual(
            SpotlightService.libraryIdentifier(
                for: LibraryReference(itemType: "audio", itemId: "audio-id")
            ),
            "audio-audio-id"
        )
        XCTAssertEqual(
            SpotlightService.libraryIdentifier(
                for: LibraryReference(itemType: "pdf", itemId: "pdf-id")
            ),
            "pdf-pdf-id"
        )
    }

    func testDetailNavigationDoesNotEquateDifferentMediaTypesWithTheSameID() throws {
        let transcript = try APIClient.makeDecoder().decode(
            Transcript.self,
            from: Data(#"{"id":"shared-id","status":"completed"}"#.utf8)
        )
        let audio = try APIClient.makeDecoder().decode(
            AudioTranscription.self,
            from: Data(#"{"id":"shared-id","status":"completed"}"#.utf8)
        )

        XCTAssertNotEqual(LibraryItem.transcript(transcript), LibraryItem.audio(audio))
    }

    func testLibraryPathEncodesCrossMediaSearchAndFilters() throws {
        let path = MediaToolsService.libraryItemsPath(
            page: 2,
            perPage: 30,
            itemType: "audio",
            status: "active",
            search: " payroll & tax ",
            sortDirection: "asc"
        )
        let components = try XCTUnwrap(URLComponents(string: path))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap {
            item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })

        XCTAssertEqual(components.path, "/library/items")
        XCTAssertEqual(query["page"], "2")
        XCTAssertEqual(query["per_page"], "30")
        XCTAssertEqual(query["type"], "audio")
        XCTAssertEqual(query["status"], "active")
        XCTAssertEqual(query["search"], "payroll & tax")
        XCTAssertEqual(query["sort_dir"], "asc")
    }
}
