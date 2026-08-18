import Foundation

/// URLSession configured for background uploads.
/// Allows the share extension to queue uploads that continue even if the extension is terminated.
final class BackgroundUploadService: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    static let shared = BackgroundUploadService()

    private struct UploadMetadata: Codable {
        let filename: String
        let bodyFilePath: String
    }

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

        do {
            try body.write(to: bodyFile, options: .atomic)
        } catch {
            print("Unable to prepare background upload: \(error)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        guard let metadata = try? JSONEncoder().encode(
            UploadMetadata(filename: filename, bodyFilePath: bodyFile.path)
        ) else {
            try? FileManager.default.removeItem(at: bodyFile)
            return
        }

        let task = session.uploadTask(with: request, fromFile: bodyFile)
        // URLSession persists taskDescription with a background task, which
        // lets us recover the temp path even after the app is relaunched.
        task.taskDescription = metadata.base64EncodedString()
        task.resume()
    }

    // MARK: - URLSessionTaskDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let metadata = task.taskDescription
            .flatMap { Data(base64Encoded: $0) }
            .flatMap { try? JSONDecoder().decode(UploadMetadata.self, from: $0) }

        if let error {
            print("Background upload failed: \(error)")
        } else if let response = task.response as? HTTPURLResponse,
                  !(200..<300).contains(response.statusCode) {
            print("Background upload rejected with HTTP \(response.statusCode)")
        } else {
            // An HTTP upload finishing only means the server accepted the file;
            // transcription remains asynchronous and must not be reported as done.
            print("Background upload complete: \(metadata?.filename ?? "unknown")")
        }

        if let bodyFilePath = metadata?.bodyFilePath {
            do {
                try FileManager.default.removeItem(atPath: bodyFilePath)
            } catch {
                if (error as NSError).code != NSFileNoSuchFileError {
                    print("Background upload temp-file cleanup failed: \(error)")
                }
            }
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
