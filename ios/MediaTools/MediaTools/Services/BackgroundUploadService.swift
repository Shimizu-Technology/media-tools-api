import Foundation

/// URLSession configured for background uploads.
/// Allows the share extension to queue uploads that continue even if the extension is terminated.
final class BackgroundUploadService: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    static let shared = BackgroundUploadService()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: "com.shimizu-technology.media-tools.background-upload"
        )
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.sharedContainerIdentifier = Configuration.appGroupIdentifier
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Queue a file for background upload.
    func uploadFile(
        at fileURL: URL,
        to endpoint: String,
        filename: String,
        mimeType: String,
        authToken: String?
    ) {
        guard let url = URL(string: Configuration.apiBaseURL + "/api/v1" + endpoint) else { return }

        // Write multipart body to temp file (background uploads require file, not data)
        let boundary = UUID().uuidString
        let tempDir = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Configuration.appGroupIdentifier
        ) ?? FileManager.default.temporaryDirectory
        let bodyFile = tempDir.appendingPathComponent(UUID().uuidString + ".upload")

        guard let fileData = try? Data(contentsOf: fileURL) else { return }

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        try? body.write(to: bodyFile)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let task = session.uploadTask(with: request, fromFile: bodyFile)
        task.taskDescription = filename
        task.resume()
    }

    // MARK: - URLSessionTaskDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            print("Background upload failed: \(error)")
        } else {
            print("Background upload complete: \(task.taskDescription ?? "unknown")")
            NotificationService.notifyTranscriptionComplete(
                title: task.taskDescription ?? "Upload complete",
                itemId: ""
            )
        }

        // Clean up temp file
        if let uploadTask = task as? URLSessionUploadTask,
           let originalRequest = uploadTask.originalRequest,
           let bodyStream = originalRequest.httpBodyStream {
            // Body file already consumed, nothing to clean
        }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.performDefaultHandling, nil)
    }
}
