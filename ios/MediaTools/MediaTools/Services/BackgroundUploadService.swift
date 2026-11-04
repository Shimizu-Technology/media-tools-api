import Foundation

enum BackgroundUploadEvent: Sendable {
    case progress(metadata: BackgroundUploadMetadata, fractionCompleted: Double)
    case completed(metadata: BackgroundUploadMetadata)
    case failed(metadata: BackgroundUploadMetadata, message: String, shouldRetry: Bool)
}

@MainActor
protocol BackgroundUploadEventReceiving: AnyObject {
    func receiveBackgroundUploadEvent(_ event: BackgroundUploadEvent)
}

/// The low-level owner of the app's background URLSessions: its own, plus one for
/// each upload the share extension started.
///
/// Authentication and API finalization intentionally live outside this type.
/// The transfer itself is a PUT to a scoped presigned URL, so iOS can finish it
/// after suspension without carrying a token that may expire mid-upload.
final class BackgroundUploadService: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    static let shared = BackgroundUploadService()
    static let sessionIdentifier = "com.shimizu-technology.media-tools.background-upload"

    @MainActor weak var receiver: (any BackgroundUploadEventReceiving)?

    /// Guards the two dictionaries below. iOS calls in on its own delegate queue.
    private let stateLock = NSLock()
    private var backgroundCompletionHandlers: [String: () -> Void] = [:]
    private var shareSessions: [String: URLSession] = [:]
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
        if identifier == Self.sessionIdentifier {
            setCompletionHandler(completionHandler, for: identifier)
            _ = session
        } else if ShareDirectUpload.isShareSession(identifier) {
            setCompletionHandler(completionHandler, for: identifier)
            attachShareSessions([identifier])
        } else {
            completionHandler()
        }
    }

    /// Reconnects to uploads the extension started. A session recreated with the
    /// same identifier receives their results, including ones that already finished.
    func attachShareSessions(_ identifiers: Set<String>) {
        stateLock.lock()
        defer { stateLock.unlock() }
        for identifier in identifiers
        where ShareDirectUpload.isShareSession(identifier) && shareSessions[identifier] == nil {
            let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
            configuration.sharedContainerIdentifier = ShareDirectUpload.appGroupIdentifier
            configuration.isDiscretionary = false
            configuration.sessionSendsLaunchEvents = true
            configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
            shareSessions[identifier] = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: nil
            )
        }
    }

    private func setCompletionHandler(_ handler: @escaping () -> Void, for identifier: String) {
        stateLock.lock()
        defer { stateLock.unlock() }
        backgroundCompletionHandlers[identifier] = handler
    }

    private func allTasks() async -> [URLSessionTask] {
        stateLock.lock()
        let sessions = [session] + Array(shareSessions.values)
        stateLock.unlock()
        var tasks: [URLSessionTask] = []
        for session in sessions {
            tasks += await withCheckedContinuation { continuation in
                session.getAllTasks { continuation.resume(returning: $0) }
            }
        }
        return tasks
    }

    func activeRecordingIDs() async -> Set<UUID> {
        Set(await allTasks().compactMap { Self.metadata(for: $0)?.recordingID })
    }

    /// Update task descriptions after a verified owner-ID migration. S3 PUTs
    /// continue independently of app authentication, so they need not restart.
    func migrateOwnerID(from clerkID: String, to userID: String) async {
        for task in await allTasks() {
            guard let metadata = Self.metadata(for: task), metadata.ownerID == clerkID else { continue }
            let updated = BackgroundUploadMetadata(
                recordingID: metadata.recordingID,
                ownerID: userID,
                filename: metadata.filename,
                objectKey: metadata.objectKey,
                sizeBytes: metadata.sizeBytes,
                mimeType: metadata.mimeType,
                contentType: metadata.contentType
            )
            task.taskDescription = try? JSONEncoder().encode(updated).base64EncodedString()
        }
    }

    func cancel(recordingIDs: Set<UUID>) async {
        guard !recordingIDs.isEmpty else { return }
        for task in await allTasks() {
            guard let recordingID = Self.metadata(for: task)?.recordingID,
                  recordingIDs.contains(recordingID)
            else { continue }
            task.cancel()
        }
    }

    /// Covers an extension upload whose share the app has not imported yet.
    func cancelUploads(ownedBy ownerID: String) async {
        for task in await allTasks() where Self.metadata(for: task)?.ownerID == ownerID {
            task.cancel()
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
        guard let identifier = session.configuration.identifier else { return }
        stateLock.lock()
        let completionHandler = backgroundCompletionHandlers.removeValue(forKey: identifier)
        // A share session holds one transfer, and iOS has reported on it.
        let finishedShareSession = shareSessions.removeValue(forKey: identifier)
        stateLock.unlock()
        finishedShareSession?.finishTasksAndInvalidate()
        guard let completionHandler else { return }
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
