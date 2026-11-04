import Foundation
import Security
import UniformTypeIdentifiers

/// Everything the app and the share extension must agree on so a share can start
/// uploading without opening the app. If any of it is missing or stale, the share
/// simply waits in the inbox for the app, exactly as it always has.
enum ShareDirectUpload {
    static let appGroupIdentifier = "group.com.shimizu-technology.media-tools"
    /// Each share gets its own background session. iOS allows one process per
    /// session, and two shares can run in two extension processes at once.
    static let sessionIdentifierPrefix = "com.shimizu-technology.media-tools.share-upload."
    /// Shares import with this content type, so the upload must use it too.
    static let contentType = "general"
    /// The extension gets this long to finish presigning. A longer wait would hold
    /// the share sheet open; the app can always send the share later.
    static let presignTimeout: TimeInterval = 12

    static func sessionIdentifier(for shareID: UUID) -> String {
        sessionIdentifierPrefix + shareID.uuidString.lowercased()
    }

    static func isShareSession(_ identifier: String) -> Bool {
        identifier.hasPrefix(sessionIdentifierPrefix)
    }

    /// The signature on a presigned URL covers this value, so the presign request
    /// and the PUT that follows it must compute the same answer.
    static func mimeType(for url: URL) -> String {
        if url.pathExtension.caseInsensitiveCompare("caf") == .orderedSame {
            // UniformTypeIdentifiers does not consistently publish a CAF MIME
            // mapping across supported iOS/macOS SDKs.
            return "audio/x-caf"
        }
        return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
    }
}

/// Describes one PUT to object storage. It travels with the task itself so iOS can
/// hand it back after the process that started the task is long gone.
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

// MARK: - Capture key

/// A scoped API key that can only presign and complete a recording upload. It is
/// bound to the account that minted it, so an upload can never land elsewhere.
struct ShareUploadCredential: Codable, Equatable, Sendable {
    let keyID: String
    let rawKey: String
    let ownerID: String
}

/// As with the device session, "locked" and "missing" are different answers:
/// a locked iPhone must not cause a second key to be minted.
enum ShareUploadCredentialLoadResult: Equatable, Sendable {
    case found(ShareUploadCredential)
    case missing
    case unavailable
}

protocol ShareUploadCredentialStoring: Sendable {
    func load() -> ShareUploadCredentialLoadResult
    func save(_ credential: ShareUploadCredential) throws
    func delete()
}

/// The one credential the extension can read. It lives in the App Group's Keychain
/// access group; the device session stays in the app's own group and never moves.
struct ShareUploadKeychainStore: ShareUploadCredentialStoring {
    private static let service = "com.shimizu-technology.media-tools.share-upload"
    private let account: String

    init(account: String = "capture-upload-key-v1") {
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: ShareDirectUpload.appGroupIdentifier,
        ]
    }

    func load() -> ShareUploadCredentialLoadResult {
        var query = baseQuery
        query[kSecReturnData as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data = result as? Data else { return .unavailable }
        guard let credential = try? JSONDecoder().decode(ShareUploadCredential.self, from: data) else {
            return .missing
        }
        return .found(credential)
    }

    func save(_ credential: ShareUploadCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let status = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
        }
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

// MARK: - Consent flags

/// The app's permission and "Automatically transcribe" answers, copied where the
/// extension can read them. `UserDefaults.standard` is private to each process.
struct ShareUploadPolicy: Codable, Equatable, Sendable {
    let ownerID: String
    /// True only with automatic-transcription consent and the setting on.
    let mayUploadAutomatically: Bool
    let apiBaseURL: String
}

protocol ShareUploadPolicyStoring: Sendable {
    func load() -> ShareUploadPolicy?
    func save(_ policy: ShareUploadPolicy) throws
    func clear()
}

/// A file rather than shared defaults: an atomic replace is seen immediately by
/// the other process, and a revoked permission must not be read from a stale cache.
struct ShareUploadPolicyFileStore: ShareUploadPolicyStoring {
    private let fileURL: URL

    init(directoryURL: URL? = nil) throws {
        let directory: URL
        if let directoryURL {
            directory = directoryURL
        } else {
            guard let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: ShareDirectUpload.appGroupIdentifier
            ) else {
                throw CocoaError(.fileNoSuchFile)
            }
            directory = container
        }
        fileURL = directory.appendingPathComponent("share-upload-policy.json")
    }

    /// Anything unreadable means no permission, so the share waits for the app.
    func load() -> ShareUploadPolicy? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ShareUploadPolicy.self, from: data)
    }

    func save(_ policy: ShareUploadPolicy) throws {
        try JSONEncoder().encode(policy).write(
            to: fileURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - Starting the upload

protocol ShareUploadHTTP: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: ShareUploadHTTP {}

protocol ShareBackgroundUploadStarting: Sendable {
    func start(
        fileURL: URL,
        uploadURL: URL,
        metadata: BackgroundUploadMetadata,
        sessionIdentifier: String
    ) throws
}

/// Hands one file to the system transfer daemon, which reads it from disk. The
/// extension never loads the audio, so a 2 GB share stays inside its memory limit.
///
/// iOS reports the result to whichever process holds the session. A transfer that
/// outlives the extension wakes the app. One that finishes first, as a short memo
/// does, comes here instead, and without this the result would simply be lost.
final class ShareBackgroundUploadStarter: NSObject, ShareBackgroundUploadStarting, URLSessionTaskDelegate, @unchecked Sendable {
    private let onFinish: @Sendable (BackgroundUploadMetadata, Int?) async -> Void

    init(onFinish: @escaping @Sendable (BackgroundUploadMetadata, Int?) async -> Void) {
        self.onFinish = onFinish
    }

    func start(
        fileURL: URL,
        uploadURL: URL,
        metadata: BackgroundUploadMetadata,
        sessionIdentifier: String
    ) throws {
        let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        configuration.sharedContainerIdentifier = ShareDirectUpload.appGroupIdentifier
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue(metadata.mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(metadata.sizeBytes), forHTTPHeaderField: "Content-Length")

        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = try JSONEncoder().encode(metadata).base64EncodedString()
        task.countOfBytesClientExpectsToSend = metadata.sizeBytes
        task.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let metadata = task.taskDescription
            .flatMap({ Data(base64Encoded: $0) })
            .flatMap({ try? JSONDecoder().decode(BackgroundUploadMetadata.self, from: $0) })
        else { return }
        let status = error == nil ? (task.response as? HTTPURLResponse)?.statusCode : nil
        // This can run after the share sheet closed, so ask iOS for the time to
        // finish. If it refuses, what was already saved lets the app take over.
        let finished = DispatchSemaphore(value: 0)
        let onFinish = self.onFinish
        Task {
            await onFinish(metadata, status)
            finished.signal()
        }
        ProcessInfo.processInfo.performExpiringActivity(withReason: "Finish a shared recording") { expired in
            guard !expired else { return }
            finished.wait()
        }
    }
}

/// The extension's side of a direct upload. The share is already saved by the time
/// this runs, so every failure here leaves it waiting for the app and loses nothing.
struct ShareDirectUploader {
    enum Outcome: Equatable {
        case uploading
        case savedForApp
    }

    let inbox: ShareInboxStore
    let credentials: any ShareUploadCredentialStoring
    let policy: any ShareUploadPolicyStoring
    let http: any ShareUploadHTTP
    let starter: any ShareBackgroundUploadStarting

    /// Asked before staging, so the reservation is in the first manifest the app
    /// could ever read. Otherwise it could import the share while this presigns.
    func eligibleOwnerID() -> String? {
        guard let policy = policy.load(), policy.mayUploadAutomatically,
              URL(string: policy.apiBaseURL) != nil,
              case .found(let credential) = credentials.load(),
              credential.ownerID == policy.ownerID
        else { return nil }
        return credential.ownerID
    }

    func start(_ item: ShareInboxStore.Item) async -> Outcome {
        guard item.resolvedKind == .audio,
              item.directUpload != nil,
              let ownerID = item.ownerID,
              let startingPolicy = policy.load(),
              case .found(let credential) = credentials.load(),
              credential.ownerID == ownerID,
              startingPolicy.ownerID == ownerID,
              startingPolicy.mayUploadAutomatically
        else {
            return releaseReservation(item)
        }
        do {
            let fileURL = inbox.fileURL(for: item)
            guard let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init),
                  size > 0
            else {
                return releaseReservation(item)
            }
            let mimeType = ShareDirectUpload.mimeType(for: fileURL)
            let presign = try await presign(
                filename: item.originalName,
                mimeType: mimeType,
                sizeBytes: size,
                credential: credential,
                apiBaseURL: startingPolicy.apiBaseURL
            )
            let sessionIdentifier = ShareDirectUpload.sessionIdentifier(for: item.id)
            var started = item
            started.directUpload?.sessionIdentifier = sessionIdentifier
            started.directUpload?.objectKey = presign.objectKey
            started.directUpload?.sizeBytes = size
            started.directUpload?.mimeType = mimeType
            // Saved before the task exists: if the app sees a share with no running
            // task it uploads again, but it can never miss one that is running.
            try inbox.update(started)
            // Presigning takes real time. In that time the person may have revoked
            // permission, turned this off, or signed out, and the answer read earlier
            // no longer speaks for them. The app may also have taken the share over.
            guard policy.load() == startingPolicy,
                  credentials.load() == .found(credential),
                  inbox.transferClaim(shareID: item.id) == nil
            else {
                return releaseReservation(item)
            }
            try starter.start(
                fileURL: fileURL,
                uploadURL: presign.uploadURL,
                metadata: BackgroundUploadMetadata(
                    recordingID: item.id,
                    ownerID: ownerID,
                    filename: item.originalName,
                    objectKey: presign.objectKey,
                    sizeBytes: size,
                    mimeType: mimeType,
                    contentType: ShareDirectUpload.contentType
                ),
                sessionIdentifier: sessionIdentifier
            )
            return .uploading
        } catch ShareUploadRejection.invalidKey {
            // A password reset or email change revoked every key. The app mints
            // another once it is signed in again.
            credentials.delete()
            return releaseReservation(item)
        } catch {
            return releaseReservation(item)
        }
    }

    /// The transfer ended while this extension was still running. Saved first, so
    /// the app never sends these bytes again, then finished here so a share needs
    /// no one to open the app. The server treats a repeated completion as the same
    /// upload, so the app can safely complete it again when it imports the share.
    func finishTransfer(_ metadata: BackgroundUploadMetadata, statusCode: Int?) async {
        guard var item = try? inbox.pendingItems().first(where: { $0.id == metadata.recordingID }),
              item.directUpload?.objectKey == metadata.objectKey
        else { return }
        guard let statusCode, (200..<300).contains(statusCode) else {
            _ = releaseReservation(item)
            return
        }
        // If the app already gave up on this transfer, it is sending its own copy, and
        // completing this object too would create a second transcription.
        guard let objectKey = item.directUpload?.objectKey,
              case .held(.extensionFinished(let winner)) = inbox.claimTransfer(
                  .extensionFinished(objectKey: objectKey),
                  shareID: item.id
              ),
              winner == objectKey
        else { return }
        item.directUpload?.uploadFinished = true
        try? inbox.update(item)
        guard let policy = policy.load(), policy.mayUploadAutomatically,
              policy.ownerID == metadata.ownerID,
              case .found(let credential) = credentials.load(),
              credential.ownerID == metadata.ownerID,
              let url = URL(string: policy.apiBaseURL + "/api/v1/audio/uploads/complete")
        else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = ShareDirectUpload.presignTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(credential.rawKey, forHTTPHeaderField: "X-API-Key")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "object_key": metadata.objectKey,
            "original_name": metadata.filename,
            "size_bytes": metadata.sizeBytes,
            "content_type": metadata.contentType,
        ])
        // Any failure leaves the upload marked finished, for the app to complete.
        guard let (_, response) = try? await http.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 401
        else { return }
        credentials.delete()
    }

    /// If this write fails, the reservation expires and the app imports the share.
    private func releaseReservation(_ item: ShareInboxStore.Item) -> Outcome {
        var released = item
        released.directUpload = nil
        try? inbox.update(released)
        return .savedForApp
    }

    private enum ShareUploadRejection: Error {
        case invalidKey
        case failed
    }

    private struct PresignResponse {
        let uploadURL: URL
        let objectKey: String
    }

    private func presign(
        filename: String,
        mimeType: String,
        sizeBytes: Int64,
        credential: ShareUploadCredential,
        apiBaseURL: String
    ) async throws -> PresignResponse {
        guard let url = URL(string: apiBaseURL + "/api/v1/audio/uploads/presign") else {
            throw ShareUploadRejection.failed
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = ShareDirectUpload.presignTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(credential.rawKey, forHTTPHeaderField: "X-API-Key")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "filename": filename,
            "content_type": mimeType,
            "size_bytes": sizeBytes,
        ])
        let (data, response) = try await http.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw ShareUploadRejection.failed
        }
        if status == 401 { throw ShareUploadRejection.invalidKey }
        guard (200..<300).contains(status),
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawUploadURL = body["upload_url"] as? String,
              let uploadURL = URL(string: rawUploadURL),
              let objectKey = body["object_key"] as? String
        else {
            throw ShareUploadRejection.failed
        }
        return PresignResponse(uploadURL: uploadURL, objectKey: objectKey)
    }
}
