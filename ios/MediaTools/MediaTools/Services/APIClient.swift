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

        self.decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601

        self.encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    // MARK: - Auth

    private func authHeaders() async -> [String: String] {
        var headers: [String: String] = [
            "Content-Type": "application/json",
            "Accept": "application/json"
        ]

        // Get Clerk session token
        if let token = try? await Clerk.shared.session?.getToken() {
            headers["Authorization"] = "Bearer \(token)"
        }

        return headers
    }

    // MARK: - HTTP Methods

    func get<T: Decodable>(_ path: String) async throws -> T {
        let url = URL(string: baseURL + path)!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in await authHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        let url = URL(string: baseURL + path)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(body)
        for (key, value) in await authHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    func post<B: Encodable>(_ path: String, body: B) async throws {
        let url = URL(string: baseURL + path)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(body)
        for (key, value) in await authHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
    }

    func delete(_ path: String) async throws {
        let url = URL(string: baseURL + path)!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        for (key, value) in await authHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)
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

        var headers = await authHeaders()
        headers["Content-Type"] = "multipart/form-data; boundary=\(boundary)"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

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

        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Validation

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.message
                ?? String(data: data, encoding: .utf8)
                ?? "Unknown error"
            throw APIError.httpError(statusCode: http.statusCode, message: message)
        }
    }
}

// MARK: - Error Types

enum APIError: LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid server response"
        case .httpError(let code, let message):
            return "HTTP \(code): \(message)"
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
