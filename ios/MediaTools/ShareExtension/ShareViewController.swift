import UIKit
import UniformTypeIdentifiers

/// Saves shared files and links on-device, then closes itself. The main app
/// handles account selection, AI processing consent, upload, and retry.
final class ShareViewController: UIViewController {
    private let symbol = UIImageView(image: UIImage(systemName: "waveform.circle.fill"))
    private let statusLabel = UILabel()
    private let activity = UIActivityIndicatorView(style: .medium)
    private let doneButton = UIButton(type: .system)

    /// Long enough to read the confirmation without making a share feel slow.
    private static let successDismissDelay: TimeInterval = 1

    // The host reads the presentation style before showing this controller. A
    // system sheet would take nearly the whole screen for one line of status.
    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        modalPresentationStyle = .overFullScreen
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        modalPresentationStyle = .overFullScreen
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.25)

        let card = UIView()
        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 28
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        symbol.tintColor = .systemTeal
        symbol.contentMode = .scaleAspectFit
        symbol.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.text = "Saving to Media Tools…"
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        activity.startAnimating()
        activity.translatesAutoresizingMaskIntoConstraints = false

        doneButton.setTitle("Done", for: .normal)
        doneButton.addTarget(self, action: #selector(done), for: .touchUpInside)
        doneButton.isHidden = true
        doneButton.translatesAutoresizingMaskIntoConstraints = false

        [symbol, statusLabel, activity, doneButton].forEach(card.addSubview)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            card.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            symbol.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            symbol.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            symbol.widthAnchor.constraint(equalToConstant: 44),
            symbol.heightAnchor.constraint(equalToConstant: 44),
            statusLabel.topAnchor.constraint(equalTo: symbol.bottomAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            activity.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            activity.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            activity.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
            doneButton.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            doneButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            doneButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        saveOfferedItems()
    }

    @objc private func done() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func saveOfferedItems() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []
        let files = providers.compactMap { provider -> (NSItemProvider, String)? in
            Self.fileTypeIdentifier(of: provider).map { (provider, $0) }
        }
        let links = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }

        let group = DispatchGroup()
        let lock = NSLock()
        var saved = 0
        var failure: String?
        let record: (Result<Void, Error>) -> Void = { result in
            lock.lock()
            defer { lock.unlock() }
            switch result {
            case .success:
                saved += 1
            case .failure(let error):
                failure = error.localizedDescription
            }
        }

        // A page shared with both a file and its URL describes one thing, so a
        // link is used only when nothing better came with it.
        if !files.isEmpty {
            for (provider, typeIdentifier) in files {
                group.enter()
                saveFile(from: provider, typeIdentifier: typeIdentifier) { result in
                    record(result)
                    group.leave()
                }
            }
        } else if let link = links.first {
            group.enter()
            saveLink(from: link) { result in
                record(result)
                group.leave()
            }
        } else {
            finish(failure: "Share an audio file, an MP4, MOV, or WebM video, a PDF, or a video link.")
            return
        }

        group.notify(queue: .main) { [weak self] in
            if let failure, saved == 0 {
                self?.finish(failure: failure)
            } else if let failure {
                self?.finish(failure: "Saved \(saved). One item could not be saved: \(failure)")
            } else {
                self?.finishSuccessfully()
            }
        }
    }

    /// Prefer the concrete registered type, such as M4A audio, over its generic
    /// parent, so iOS hands over a file carrying the right extension.
    private static func fileTypeIdentifier(of provider: NSItemProvider) -> String? {
        let accepted: [UTType] = [.audio, .mpeg4Movie, .quickTimeMovie, .pdf] + (UTType("org.webmproject.webm").map { [$0] } ?? [])
        return provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return accepted.contains { type.conforms(to: $0) }
        }
    }

    private func saveFile(
        from provider: NSItemProvider,
        typeIdentifier: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { temporaryURL, error in
            guard let temporaryURL else {
                completion(.failure(error ?? CocoaError(.fileReadUnknown)))
                return
            }
            // File representations are temporary. Copy before returning from
            // this callback and before telling iOS the share is done.
            completion(Result {
                _ = try ShareInboxStore().stageFile(
                    from: temporaryURL,
                    originalName: provider.suggestedName ?? temporaryURL.lastPathComponent,
                    contentTypeExtension: UTType(typeIdentifier)?.preferredFilenameExtension
                )
            })
        }
    }

    private func saveLink(
        from provider: NSItemProvider,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        _ = provider.loadObject(ofClass: URL.self) { url, error in
            guard let url else {
                completion(.failure(error ?? ShareInboxStore.ShareError.unsupportedLink))
                return
            }
            completion(Result {
                _ = try ShareInboxStore().stageLink(url, title: provider.suggestedName)
            })
        }
    }

    private func finishSuccessfully() {
        activity.stopAnimating()
        symbol.image = UIImage(systemName: "checkmark.circle.fill")
        symbol.tintColor = .systemGreen
        statusLabel.text = "Saved to Media Tools"
        UIAccessibility.post(notification: .announcement, argument: statusLabel.text)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.successDismissDelay) { [weak self] in
            self?.done()
        }
    }

    /// A failure stays on screen until dismissed because nothing was saved and
    /// the person needs to know that.
    private func finish(failure message: String) {
        activity.stopAnimating()
        symbol.image = UIImage(systemName: "exclamationmark.circle.fill")
        symbol.tintColor = .systemRed
        statusLabel.text = message
        statusLabel.textColor = .systemRed
        doneButton.isHidden = false
    }
}
