import UIKit
import Social
import UniformTypeIdentifiers

/// Share Sheet extension for Media Tools.
///
/// Accepts:
/// - URLs (video links → transcribe)
/// - Audio files → upload & transcribe
/// - PDF files → upload & extract
///
/// Auth: reads the Clerk session token from shared Keychain group.
class ShareViewController: SLComposeServiceViewController {

    private var sharedURL: URL?
    private var sharedFileURL: URL?
    private var sharedFileType: UTType?

    override func isContentValid() -> Bool {
        return sharedURL != nil || sharedFileURL != nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Media Tools"
        extractSharedContent()
    }

    override func didSelectPost() {
        Task {
            await processSharedContent()
            self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    override func configurationItems() -> [Any]! {
        return []
    }

    // MARK: - Extract shared content

    private func extractSharedContent() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return }

        for item in items {
            guard let attachments = item.attachments else { continue }

            for provider in attachments {
                // Check for URL
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] item, _ in
                        if let url = item as? URL {
                            DispatchQueue.main.async {
                                self?.sharedURL = url
                                self?.placeholder = url.absoluteString
                            }
                        }
                    }
                }

                // Check for audio
                if provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.audio.identifier, options: nil) { [weak self] item, _ in
                        if let url = item as? URL {
                            DispatchQueue.main.async {
                                self?.sharedFileURL = url
                                self?.sharedFileType = .audio
                                self?.placeholder = url.lastPathComponent
                            }
                        }
                    }
                }

                // Check for PDF
                if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.pdf.identifier, options: nil) { [weak self] item, _ in
                        if let url = item as? URL {
                            DispatchQueue.main.async {
                                self?.sharedFileURL = url
                                self?.sharedFileType = .pdf
                                self?.placeholder = url.lastPathComponent
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Process

    private func processSharedContent() async {
        let baseURL = apiBaseURL + "/api/v1"

        if let url = sharedURL {
            // Submit URL for transcription
            await submitURL(url.absoluteString, baseURL: baseURL)
        } else if let fileURL = sharedFileURL, let type = sharedFileType {
            await uploadFile(fileURL, type: type, baseURL: baseURL)
        }
    }

    private func submitURL(_ url: String, baseURL: String) async {
        guard let endpoint = URL(string: baseURL + "/transcripts") else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)

        let body = ["url": url]
        request.httpBody = try? JSONEncoder().encode(body)

        _ = try? await URLSession.shared.data(for: request)
    }

    private func uploadFile(_ fileURL: URL, type: UTType, baseURL: String) async {
        let path = type == .pdf ? "/pdf/extractions" : "/audio/transcriptions"
        guard let endpoint = URL(string: baseURL + path) else { return }

        let boundary = UUID().uuidString
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)

        guard let fileData = try? Data(contentsOf: fileURL) else { return }

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        let mimeType = type == .pdf ? "application/pdf" : "audio/m4a"
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Auth

    private func applyAuth(to request: inout URLRequest) {
        // Read token from shared Keychain
        if let token = readTokenFromKeychain() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

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
}
