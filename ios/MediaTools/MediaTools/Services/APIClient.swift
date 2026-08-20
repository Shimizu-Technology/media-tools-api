import Foundation
import ClerkKit

/// HTTP client for the Media Tools API.
/// Uses Clerk session token for authentication.
actor APIClient {
    static let shared = APIClient()

    private let baseURL: String
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    private init() {
        self.baseURL = Configuration.apiBaseURL + "/api/v1"
        self.session = URLSession.shared

        self.decoder = Self.makeDecoder()
        self.encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    /// Keep API date parsing in one testable place. Value-type format styles are
    /// safe to capture in JSONDecoder's @Sendable custom decoding closure, unlike
    /// the older ISO8601DateFormatter reference type.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        // Go API returns dates with fractional seconds (e.g. "2026-02-20T00:33:45.123Z")
        // which the default .iso8601 can't parse. Use a custom formatter.
        let fractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let wholeSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            if let date = try? fractionalSeconds.parse(str) { return date }
            if let date = try? wholeSeconds.parse(str) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(str)")
        }
        return decoder
    }

    // MARK: - Auth

    private func authHeaders(forceRefresh: Bool = false) async throws -> [String: String] {
        var headers: [String: String] = [
            "Content-Type": "application/json",
            "Accept": "application/json"
        ]

        guard !Configuration.clerkPublishableKey.isEmpty else {
            throw APIError.authenticationRequired(
                message: "Media Tools authentication is not configured in this build."
            )
        }
        guard let session = await Clerk.shared.session else {
            throw APIError.authenticationRequired(message: "Sign in to continue.")
        }
        let options = Session.GetTokenOptions(skipCache: forceRefresh)
        let token: String?
        do {
            token = try await session.getToken(options)
        } catch {
            throw APIError.authenticationRequired(
                message: "Your sign-in session could not be refreshed. Sign out and sign in again."
            )
        }
        guard let token, !token.isEmpty else {
            throw APIError.authenticationRequired(
                message: "Your sign-in session could not be refreshed. Sign out and sign in again."
            )
        }
        headers["Authorization"] = "Bearer \(token)"

        return headers
    }

    private func authenticatedRequest(
        from originalRequest: URLRequest,
        forceRefresh: Bool = false
    ) async throws -> URLRequest {
        var request = originalRequest
        for (key, value) in try await authHeaders(forceRefresh: forceRefresh) {
            // Multipart requests carry their boundary in Content-Type; never
            // replace it with the JSON default while applying auth headers.
            if key.caseInsensitiveCompare("Content-Type") == .orderedSame,
               request.value(forHTTPHeaderField: key) != nil {
                continue
            }
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    /// Send an authenticated API request and recover once from a rejected
    /// cached Clerk token. The retry is deliberately limited to one attempt so
    /// a revoked session never creates a request loop.
    private func data(for originalRequest: URLRequest) async throws -> (Data, URLResponse) {
        let request = try await authenticatedRequest(from: originalRequest)
        let firstResponse = try await session.data(for: request)
        guard (firstResponse.1 as? HTTPURLResponse)?.statusCode == 401 else {
            return firstResponse
        }

        let retryRequest = try await authenticatedRequest(from: originalRequest, forceRefresh: true)
        return try await session.data(for: retryRequest)
    }

    private func upload(
        for originalRequest: URLRequest,
        fromFile fileURL: URL
    ) async throws -> (Data, URLResponse) {
        let request = try await authenticatedRequest(from: originalRequest)
        let firstResponse = try await session.upload(for: request, fromFile: fileURL)
        guard (firstResponse.1 as? HTTPURLResponse)?.statusCode == 401 else {
            return firstResponse
        }

        let retryRequest = try await authenticatedRequest(from: originalRequest, forceRefresh: true)
        return try await session.upload(for: retryRequest, fromFile: fileURL)
    }

    // MARK: - HTTP Methods

    func get<T: Decodable>(_ path: String) async throws -> T {
        let url = URL(string: baseURL + path)!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await data(for: request)
        try validateResponse(response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        let url = URL(string: baseURL + path)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await data(for: request)
        try validateResponse(response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    func post<B: Encodable>(_ path: String, body: B) async throws {
        let url = URL(string: baseURL + path)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await data(for: request)
        try validateResponse(response, data: data)
    }

    func delete(_ path: String) async throws {
        let url = URL(string: baseURL + path)!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (data, response) = try await data(for: request)
        try validateResponse(response, data: data)
    }

    /// Upload raw data (audio file) with multipart form.
    func upload<T: Decodable>(
        _ path: String,
        fileData: Data,
        filename: String,
        mimeType: String,
        fields: [String: String] = [:]
    ) async throws -> T {
        let boundary = UUID().uuidString
        let url = URL(string: baseURL + path)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        // Text fields
        for (key, value) in fields {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }
        // File
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        body.appendString("\r\n--\(boundary)--\r\n")

        request.httpBody = body

        let (data, response) = try await data(for: request)
        try validateResponse(response, data: data)
        if let raw = String(data: data, encoding: .utf8) {
            print("📦 Upload response: \(raw.prefix(500))")
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            print("❌ Upload decode error: \(error)")
            throw error
        }
    }

    /// Upload a source file without materializing either the source or the
    /// multipart body in memory. This keeps long recordings within a stable
    /// memory envelope when direct object storage is unavailable.
    func uploadFile<T: Decodable>(
        _ path: String,
        fileURL: URL,
        filename: String,
        mimeType: String,
        fields: [String: String] = [:]
    ) async throws -> T {
        let boundary = UUID().uuidString
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("upload")
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        try Self.writeMultipartBody(
            to: bodyURL,
            sourceURL: fileURL,
            filename: filename,
            mimeType: mimeType,
            fields: fields,
            boundary: boundary
        )

        let url = URL(string: baseURL + path)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await upload(for: request, fromFile: bodyURL)
        try validateResponse(response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    /// Send a file to a presigned object-storage URL. Presigned uploads must not
    /// include Clerk credentials because the URL itself grants scoped access.
    func putFile(at fileURL: URL, to uploadURL: URL, mimeType: String) async throws {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        try validateResponse(response, data: data)
    }

    static func writeMultipartBody(
        to destinationURL: URL,
        sourceURL: URL,
        filename: String,
        mimeType: String,
        fields: [String: String],
        boundary: String
    ) throws {
        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw APIError.invalidFile(message: "Could not prepare the recording for upload.")
        }
        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }

        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            try output.write(contentsOf: Data("--\(boundary)\r\n".utf8))
            try output.write(
                contentsOf: Data("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".utf8))
            try output.write(contentsOf: Data("\(value)\r\n".utf8))
        }

        let safeFilename =
            filename
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        try output.write(contentsOf: Data("--\(boundary)\r\n".utf8))
        try output.write(
            contentsOf: Data(
                "Content-Disposition: form-data; name=\"file\"; filename=\"\(safeFilename)\"\r\n".utf8))
        try output.write(contentsOf: Data("Content-Type: \(mimeType)\r\n\r\n".utf8))

        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }

    // MARK: - Validation

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            let message = errorResponse?.message
                ?? String(data: data, encoding: .utf8)
                ?? "Unknown error"
            throw APIError.httpError(
                statusCode: http.statusCode,
                code: errorResponse?.error,
                message: message
            )
        }
    }
}

// MARK: - Error Types

enum APIError: LocalizedError {
    case invalidResponse
    case invalidFile(message: String)
    case authenticationRequired(message: String)
    case httpError(statusCode: Int, code: String? = nil, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid server response"
        case .invalidFile(let message):
            return message
        case .authenticationRequired(let message):
            return message
        case .httpError(let statusCode, _, let message):
            return "HTTP \(statusCode): \(message)"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .invalidResponse:
            return true
        case .invalidFile:
            return false
        case .authenticationRequired:
            // Clerk may still be restoring a persisted session during a
            // background wake-up. Durable uploads should wait and retry rather
            // than turning a safe local recording into a terminal failure.
            return true
        case .httpError(let statusCode, _, _):
            return statusCode == 408 || statusCode == 429 || statusCode >= 500
        }
    }

    var permitsMultipartUploadFallback: Bool {
        switch self {
        case .httpError(let statusCode, let code, _):
            // A 404 keeps the current app compatible with older/self-hosted
            // servers that support multipart upload but predate presigning.
            return statusCode == 404 || code == "storage_unavailable"
        default:
            return false
        }
    }
}

struct ErrorResponse: Decodable {
    let error: String?
    let message: String?
}

// MARK: - Data Extension

extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
