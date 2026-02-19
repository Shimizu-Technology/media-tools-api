import Foundation
import WatchConnectivity

/// Watch-side WatchConnectivity handler.
/// Sends audio to iPhone, receives transcription status updates.
final class WatchConnectivityService: NSObject, ObservableObject {
    static let shared = WatchConnectivityService()

    /// Current transcription being tracked.
    @Published var currentTranscription: WatchTranscription?

    /// Recent items synced from iPhone.
    @Published var recentItems: [WatchRecentItem] = []

    /// Whether the iPhone is reachable.
    @Published var isPhoneReachable = false

    /// Whether a file transfer is in progress.
    @Published var isTransferring = false

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    /// Send recorded audio file to iPhone for transcription.
    func sendAudioToPhone(fileURL: URL, duration: TimeInterval, contentType: String = "voice_memo") {
        guard WCSession.default.activationState == .activated else {
            print("WCSession not activated")
            // Fall back to direct API upload
            Task { await uploadDirectly(fileURL: fileURL, contentType: contentType) }
            return
        }

        isTransferring = true
        currentTranscription = WatchTranscription(
            id: nil,
            status: .transferring,
            title: "Sending to iPhone...",
            wordCount: 0
        )

        let metadata: [String: Any] = [
            WatchMessage.filenameKey: "watch-\(Int(Date().timeIntervalSince1970)).m4a",
            WatchMessage.durationKey: duration,
            WatchMessage.contentTypeKey: contentType,
            WatchMessage.recordedAtKey: Date().timeIntervalSince1970,
        ]

        let transfer = WCSession.default.transferFile(fileURL, metadata: metadata)
        print("File transfer started: \(transfer.isTransferring)")
    }

    /// Direct upload to API (fallback when iPhone not reachable).
    private func uploadDirectly(fileURL: URL, contentType: String) async {
        await MainActor.run {
            currentTranscription = WatchTranscription(
                id: nil,
                status: .uploading,
                title: "Uploading directly...",
                wordCount: 0
            )
        }

        do {
            let data = try Data(contentsOf: fileURL)

            // Use shared keychain token
            let token = readTokenFromKeychain()
            guard let url = URL(string: apiBaseURL + "/api/v1/audio/transcriptions") else { return }

            let boundary = UUID().uuidString
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            if let token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            var body = Data()
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"content_type\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(contentType)\r\n".data(using: .utf8)!)
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"watch-recording.m4a\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
            request.httpBody = body

            let (responseData, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                if let result = try? JSONDecoder().decode(DirectUploadResponse.self, from: responseData) {
                    await MainActor.run {
                        currentTranscription = WatchTranscription(
                            id: result.id,
                            status: .processing,
                            title: result.title ?? "Processing...",
                            wordCount: 0
                        )
                    }
                    // Start polling
                    await pollForCompletion(id: result.id)
                }
            } else {
                await MainActor.run {
                    currentTranscription = WatchTranscription(
                        id: nil,
                        status: .failed,
                        title: "Upload failed",
                        wordCount: 0
                    )
                }
            }
        } catch {
            await MainActor.run {
                currentTranscription = WatchTranscription(
                    id: nil,
                    status: .failed,
                    title: "Error: \(error.localizedDescription)",
                    wordCount: 0
                )
            }
        }
    }

    /// Poll API for transcription completion (used in direct upload mode).
    private func pollForCompletion(id: String) async {
        let token = readTokenFromKeychain()
        guard let url = URL(string: apiBaseURL + "/api/v1/audio/transcriptions/\(id)") else { return }

        for _ in 0..<60 { // Max 5 minutes
            try? await Task.sleep(for: .seconds(5))

            var request = URLRequest(url: url)
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let result = try? JSONDecoder().decode(DirectUploadResponse.self, from: data) else {
                continue
            }

            let status = result.status ?? "pending"

            await MainActor.run {
                currentTranscription = WatchTranscription(
                    id: id,
                    status: TranscriptionStatus(rawValue: status) ?? .processing,
                    title: result.title ?? "Processing...",
                    wordCount: result.wordCount ?? 0
                )
            }

            if status == "completed" || status == "failed" {
                break
            }
        }
    }

    /// Request fresh data from iPhone.
    func requestStatusFromPhone() {
        guard WCSession.default.isReachable else { return }

        WCSession.default.sendMessage(
            [WatchMessage.typeKey: WatchMessage.requestStatus],
            replyHandler: { reply in
                self.parseRecentItems(from: reply)
            },
            errorHandler: { error in
                print("Status request failed: \(error)")
            }
        )
    }

    // MARK: - Keychain (shared with iPhone)

    private func readTokenFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.shimizu-technology.media-tools.auth",
            kSecAttrAccessGroup as String: "group.com.shimizu-technology.media-tools",
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private var apiBaseURL: String {
        #if DEBUG
        return "http://localhost:8080"
        #else
        return "https://media-tools-api.onrender.com"
        #endif
    }

    // MARK: - Parse Messages

    private func parseRecentItems(from message: [String: Any]) {
        guard let items = message["items"] as? [[String: Any]] else { return }

        DispatchQueue.main.async {
            self.recentItems = items.compactMap { dict in
                guard let id = dict[WatchMessage.idKey] as? String,
                      let title = dict[WatchMessage.titleKey] as? String,
                      let status = dict[WatchMessage.statusKey] as? String else { return nil }
                let wordCount = dict[WatchMessage.wordCountKey] as? Int ?? 0
                return WatchRecentItem(id: id, title: title, status: status, wordCount: wordCount)
            }
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityService: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isPhoneReachable = session.isReachable
        }
        if error == nil {
            requestStatusFromPhone()
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isPhoneReachable = session.isReachable
        }
    }

    // Receive status updates from iPhone
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let type = message[WatchMessage.typeKey] as? String

        DispatchQueue.main.async {
            switch type {
            case WatchMessage.transcriptionUpdate, WatchMessage.transcriptionComplete:
                let id = message[WatchMessage.idKey] as? String
                let status = message[WatchMessage.statusKey] as? String ?? "processing"
                let title = message[WatchMessage.titleKey] as? String ?? "Processing..."
                let wordCount = message[WatchMessage.wordCountKey] as? Int ?? 0

                self.currentTranscription = WatchTranscription(
                    id: id,
                    status: TranscriptionStatus(rawValue: status) ?? .processing,
                    title: title,
                    wordCount: wordCount
                )
                self.isTransferring = false

            case WatchMessage.transcriptionFailed:
                let title = message[WatchMessage.titleKey] as? String ?? "Transcription failed"
                self.currentTranscription = WatchTranscription(
                    id: nil,
                    status: .failed,
                    title: title,
                    wordCount: 0
                )
                self.isTransferring = false

            default:
                break
            }
        }
    }

    // Receive application context (deferred updates)
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let type = applicationContext[WatchMessage.typeKey] as? String

        if type == WatchMessage.recentItems {
            parseRecentItems(from: applicationContext)
        } else if type == WatchMessage.transcriptionUpdate {
            session(session, didReceiveMessage: applicationContext)
        }
    }
}

// MARK: - Models

struct WatchTranscription: Identifiable {
    let id: String?
    let status: TranscriptionStatus
    let title: String
    let wordCount: Int

    var stableId: String { id ?? UUID().uuidString }
}

enum TranscriptionStatus: String {
    case transferring
    case uploading
    case pending
    case processing
    case completed
    case failed
}

struct WatchRecentItem: Identifiable {
    let id: String
    let title: String
    let status: String
    let wordCount: Int
}

struct DirectUploadResponse: Codable {
    let id: String
    let title: String?
    let status: String?
    let wordCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, status
        case wordCount = "word_count"
    }
}
