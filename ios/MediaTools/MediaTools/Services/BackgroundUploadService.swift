import Foundation

struct BackgroundUploadMetadata: Codable, Equatable, Sendable {
    let recordingID: UUID
    let ownerID: String?
    let filename: String
    let objectKey: String
    let sizeBytes: Int64
    let mimeType: String
    let contentType: String

    init(
        recordingID: UUID,
        ownerID: String? = nil,
        filename: String,
        objectKey: String,
        sizeBytes: Int64,
        mimeType: String,
        contentType: String
    ) {
        self.recordingID = recordingID
        self.ownerID = ownerID
        self.filename = filename
        self.objectKey = objectKey
        self.sizeBytes = sizeBytes
        self.mimeType = mimeType
        self.contentType = contentType
    }
}

enum BackgroundUploadEvent: Sendable {
    case progress(metadata: BackgroundUploadMetadata, fractionCompleted: Double)
    case completed(metadata: BackgroundUploadMetadata)
    case failed(metadata: BackgroundUploadMetadata, message: String, shouldRetry: Bool)
}

@MainActor
protocol BackgroundUploadEventReceiving: AnyObject {
    func receiveBackgroundUploadEvent(_ event: BackgroundUploadEvent)
}

/// The low-level owner of the app's single background URLSession.
///
/// Authentication and API finalization intentionally live outside this type.
/// The transfer itself is a PUT to a scoped presigned URL, so iOS can finish it
/// after suspension without carrying a Clerk token that may expire mid-upload.
final class BackgroundUploadService: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    static let shared = BackgroundUploadService()
    static let sessionIdentifier = "com.shimizu-technology.media-tools.background-upload"

    @MainActor weak var receiver: (any BackgroundUploadEventReceiving)?

    private var backgroundCompletionHandler: (() -> Void)?
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: Self.sessionIdentifier
        )
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
        // Recreate the session during every launch so iOS can reassociate tasks
        // that were handed to the background transfer daemon earlier.
        _ = session
    }

    @discardableResult
    func enqueue(
        fileURL: URL,
        uploadURL: URL,
        metadata: BackgroundUploadMetadata,
        beforeResume: (Int) -> Void
    ) throws -> Int {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw APIError.invalidFile(message: "The saved recording is no longer available.")
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue(metadata.mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(metadata.sizeBytes), forHTTPHeaderField: "Content-Length")

        let encodedMetadata = try JSONEncoder().encode(metadata).base64EncodedString()
        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = encodedMetadata
        task.countOfBytesClientExpectsToSend = metadata.sizeBytes
        beforeResume(task.taskIdentifier)
        task.resume()
        return task.taskIdentifier
    }

    func acceptBackgroundEvents(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == Self.sessionIdentifier else {
            completionHandler()
            return
        }
        backgroundCompletionHandler = completionHandler
        _ = session
    }

    func activeRecordingIDs() async -> Set<UUID> {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                let identifiers = tasks.compactMap { Self.metadata(for: $0)?.recordingID }
                continuation.resume(returning: Set(identifiers))
            }
        }
    }

    func cancel(recordingIDs: Set<UUID>) async {
        guard !recordingIDs.isEmpty else { return }
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                for task in tasks {
                    guard let recordingID = Self.metadata(for: task)?.recordingID,
                          recordingIDs.contains(recordingID)
                    else { continue }
                    task.cancel()
                }
                continuation.resume()
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let metadata = Self.metadata(for: task) else { return }
        let expected = totalBytesExpectedToSend > 0
            ? totalBytesExpectedToSend : metadata.sizeBytes
        let fraction = expected > 0 ? Double(totalBytesSent) / Double(expected) : 0
        emit(.progress(metadata: metadata, fractionCompleted: fraction))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let metadata = Self.metadata(for: task) else { return }
        if let error {
            let urlError = error as? URLError
            let permanentCancellation = urlError?.code == .cancelled
            emit(.failed(
                metadata: metadata,
                message: error.localizedDescription,
                shouldRetry: !permanentCancellation
            ))
            return
        }

        guard let response = task.response as? HTTPURLResponse else {
            emit(.failed(
                metadata: metadata,
                message: "The upload server returned an invalid response.",
                shouldRetry: true
            ))
            return
        }
        guard (200..<300).contains(response.statusCode) else {
            let retryable = response.statusCode == 408
                || response.statusCode == 429
                || response.statusCode >= 500
                || response.statusCode == 401
                || response.statusCode == 403
            emit(.failed(
                metadata: metadata,
                message: "Upload was rejected with HTTP \(response.statusCode).",
                shouldRetry: retryable
            ))
            return
        }

        emit(.completed(metadata: metadata))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let completionHandler = backgroundCompletionHandler else { return }
        backgroundCompletionHandler = nil
        DispatchQueue.main.async {
            completionHandler()
        }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.performDefaultHandling, nil)
    }

    private func emit(_ event: BackgroundUploadEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.receiver?.receiveBackgroundUploadEvent(event)
        }
    }

    private static func metadata(for task: URLSessionTask) -> BackgroundUploadMetadata? {
        task.taskDescription
            .flatMap { Data(base64Encoded: $0) }
            .flatMap { try? JSONDecoder().decode(BackgroundUploadMetadata.self, from: $0) }
    }
}
