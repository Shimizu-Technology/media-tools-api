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
}
