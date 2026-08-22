import UIKit
import UniformTypeIdentifiers

/// Share Sheet extension for Media Tools.
///
/// Accepts:
/// - URLs (directs people to the main app for consent-aware transcription)
/// - Audio files (directs people to the main app for consent-aware transcription)
/// - PDF files → upload & extract
///
/// Auth: reads the Clerk session token from shared Keychain group.
class ShareViewController: UIViewController {

    private var statusLabel: UILabel!
    private var progressView: UIActivityIndicatorView!
    private var iconView: UIImageView!
    private var titleLabel: UILabel!

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        processInput()
    }

    // MARK: - UI Setup

    private func setupUI() {
        view.backgroundColor = .systemBackground

        // Container
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        // Icon
        iconView = UIImageView(image: UIImage(systemName: "waveform.circle.fill"))
        iconView.tintColor = .systemTeal
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(iconView)

        // Title
        titleLabel = UILabel()
        titleLabel.text = "Media Tools"
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        // Status
        statusLabel = UILabel()
        statusLabel.text = "Processing..."
        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)

        // Progress
        progressView = UIActivityIndicatorView(style: .medium)
        progressView.startAnimating()
        progressView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(progressView)

        // Cancel button
        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("Done", for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        cancelButton.addTarget(self, action: #selector(done), for: .touchUpInside)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            container.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),

            iconView.topAnchor.constraint(equalTo: container.topAnchor),
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 48),
            iconView.heightAnchor.constraint(equalToConstant: 48),

            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 12),
            titleLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            statusLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            progressView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
            progressView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            progressView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            cancelButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            cancelButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
    }

    @objc private func done() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    // MARK: - Process Input

    private func processInput() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            showError("No content to process")
            return
        }

        for item in items {
            guard let attachments = item.attachments else { continue }

            for provider in attachments {
                // URL
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    // A video without usable native subtitles can fall back to
                    // third-party AI transcription on the server. Keep this
                    // future extension target from bypassing the main app's
                    // account-scoped disclosure.
                    showError("Open Media Tools to review AI processing and transcribe this video.")
                    return
                }

                // Audio
                if provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
                    // Audio transcription shares the recording with third-party AI.
                    // This future extension target cannot present the main app's
                    // account-scoped disclosure, so it must never bypass consent.
                    showError("Open Media Tools to review AI processing and transcribe this audio.")
                    return
                }

                // PDF
                if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.pdf.identifier) { [weak self] item, _ in
                        if let url = item as? URL {
                            Task { await self?.uploadFile(url, endpoint: "/pdf/extract", mimeType: "application/pdf") }
                        }
                    }
                    return
                }
            }
        }

        showError("Unsupported content type")
    }

    // MARK: - API Calls

    private func uploadFile(_ fileURL: URL, endpoint: String, mimeType: String) async {
        updateStatus("Uploading \(fileURL.lastPathComponent)...")

        guard let url = URL(string: apiBaseURL + "/api/v1" + endpoint) else {
            showError("Invalid API URL")
            return
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)

        guard let fileData = try? Data(contentsOf: fileURL) else {
            showError("Cannot read file")
            return
        }

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                showSuccess("Uploaded! Processing will complete in your library.")
            } else {
                showError("Upload failed. Please try again.")
            }
        } catch {
            showError("Network error: \(error.localizedDescription)")
        }
    }

    // MARK: - Auth

    private func applyAuth(to request: inout URLRequest) {
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

    // MARK: - UI Updates

    private func updateStatus(_ text: String) {
        DispatchQueue.main.async {
            self.statusLabel.text = text
        }
    }

    private func showSuccess(_ text: String) {
        DispatchQueue.main.async {
            self.progressView.stopAnimating()
            self.iconView.image = UIImage(systemName: "checkmark.circle.fill")
            self.iconView.tintColor = .systemGreen
            self.statusLabel.text = text
            self.statusLabel.textColor = .label

            // Auto-dismiss after 2s
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.done()
            }
        }
    }

    private func showError(_ text: String) {
        DispatchQueue.main.async {
            self.progressView.stopAnimating()
            self.iconView.image = UIImage(systemName: "exclamationmark.circle.fill")
            self.iconView.tintColor = .systemRed
            self.statusLabel.text = text
            self.statusLabel.textColor = .systemRed
        }
    }

    private var apiBaseURL: String {
        #if DEBUG
        return "http://localhost:8080"
        #else
        return "https://media-tools-api.onrender.com"
        #endif
    }
}
