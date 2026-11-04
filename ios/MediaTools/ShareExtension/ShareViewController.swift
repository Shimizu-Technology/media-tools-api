import UIKit
import UniformTypeIdentifiers

/// Saves shared files and links on-device, then closes itself. Audio also starts
/// uploading from here when the app has left a capture key and permission for it,
/// and iOS wakes the app to finish. Without those, or if anything goes wrong, the
/// saved share waits for the app, which handles everything as it always has.
final class ShareViewController: UIViewController {
    private let appMark = UIImageView(image: UIImage(named: "AppMark"))
    private let appName = UILabel()
    private let closeButton = UIButton(type: .system)
    private let statusMark = UIImageView()
    private let statusBackground = UIView()
    private let activity = UIActivityIndicatorView(style: .medium)
    private let titleLabel = UILabel()
    private let noteLabel = UILabel()
    private let countdownTrack = UIView()
    private let countdownFill = UIView()
    private var countdownWidth: NSLayoutConstraint?
    private var didFinish = false

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
        // Clear, because iOS 26 can host this inside a sheet of the host app's own, out
        // of reach from here. Any color would paint that whole sheet, not just a dim.
        view.backgroundColor = .clear

        let card = UIView()
        card.backgroundColor = UIColor.ledger("surface")
        card.layer.cornerRadius = 24
        card.layer.cornerCurve = .continuous
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.22
        card.layer.shadowRadius = 24
        card.layer.shadowOffset = CGSize(width: 0, height: 8)
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = false
        scrollView.layer.cornerRadius = 24
        scrollView.layer.cornerCurve = .continuous
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(scrollView)

        let content = UIStackView()
        content.axis = .vertical
        content.alignment = .fill
        content.spacing = 16
        content.isLayoutMarginsRelativeArrangement = true
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 20, bottom: 24, trailing: 12)
        content.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(content)

        content.addArrangedSubview(makeHeader())
        content.addArrangedSubview(makeStatusRow())
        content.addArrangedSubview(makeCountdown())

        // The card hugs its content until accessibility text outgrows the screen,
        // and only then scrolls.
        let hug = scrollView.heightAnchor.constraint(equalTo: content.heightAnchor)
        hug.priority = .defaultHigh
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            card.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            card.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            scrollView.topAnchor.constraint(equalTo: card.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            hug,
            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor),
        ])

        saveOfferedItems()
    }

    private func makeHeader() -> UIView {
        appMark.contentMode = .scaleAspectFill
        appMark.layer.cornerRadius = 8
        appMark.layer.cornerCurve = .continuous
        appMark.clipsToBounds = true
        appMark.isAccessibilityElement = false

        appName.text = "Media Tools"
        appName.font = UIFontMetrics(forTextStyle: .headline)
            .scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
        appName.adjustsFontForContentSizeCategory = true
        appName.textColor = UIColor.ledger("text")
        appName.numberOfLines = 0

        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = UIColor.ledger("text-secondary")
        closeButton.addTarget(self, action: #selector(done), for: .touchUpInside)
        closeButton.accessibilityLabel = "Done"
        closeButton.isHidden = true

        let header = UIStackView(arrangedSubviews: [appMark, appName, closeButton])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 10
        NSLayoutConstraint.activate([
            appMark.widthAnchor.constraint(equalToConstant: 36),
            appMark.heightAnchor.constraint(equalToConstant: 36),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        return header
    }

    private func makeStatusRow() -> UIView {
        statusBackground.backgroundColor = .clear
        statusBackground.layer.cornerRadius = 22
        statusBackground.translatesAutoresizingMaskIntoConstraints = false

        statusMark.contentMode = .scaleAspectFit
        statusMark.translatesAutoresizingMaskIntoConstraints = false
        statusMark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .headline)
        statusMark.isAccessibilityElement = false
        statusBackground.addSubview(statusMark)

        activity.startAnimating()
        activity.color = UIColor.ledger("text-secondary")
        activity.translatesAutoresizingMaskIntoConstraints = false
        statusBackground.addSubview(activity)

        titleLabel.text = "Saving to Media Tools…"
        titleLabel.font = UIFont.ledgerSerif(.title3, weight: .semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = UIColor.ledger("text")
        titleLabel.numberOfLines = 0

        noteLabel.font = .preferredFont(forTextStyle: .subheadline)
        noteLabel.adjustsFontForContentSizeCategory = true
        noteLabel.textColor = UIColor.ledger("text-secondary")
        noteLabel.numberOfLines = 0
        noteLabel.isHidden = true

        let text = UIStackView(arrangedSubviews: [titleLabel, noteLabel])
        text.axis = .vertical
        text.spacing = 2

        let row = UIStackView(arrangedSubviews: [statusBackground, text])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8)
        NSLayoutConstraint.activate([
            statusBackground.widthAnchor.constraint(equalToConstant: 44),
            statusBackground.heightAnchor.constraint(equalToConstant: 44),
            statusMark.centerXAnchor.constraint(equalTo: statusBackground.centerXAnchor),
            statusMark.centerYAnchor.constraint(equalTo: statusBackground.centerYAnchor),
            activity.centerXAnchor.constraint(equalTo: statusBackground.centerXAnchor),
            activity.centerYAnchor.constraint(equalTo: statusBackground.centerYAnchor),
        ])
        return row
    }

    /// A thin line that empties as the card closes itself.
    private func makeCountdown() -> UIView {
        countdownTrack.backgroundColor = UIColor.ledger("separator")
        countdownTrack.layer.cornerRadius = 1.5
        countdownTrack.clipsToBounds = true
        countdownTrack.isHidden = true
        countdownTrack.isAccessibilityElement = false

        countdownFill.backgroundColor = UIColor.ledger("accent")
        countdownFill.translatesAutoresizingMaskIntoConstraints = false
        countdownTrack.addSubview(countdownFill)

        let width = countdownFill.widthAnchor.constraint(equalTo: countdownTrack.widthAnchor)
        countdownWidth = width
        NSLayoutConstraint.activate([
            countdownTrack.heightAnchor.constraint(equalToConstant: 3),
            countdownFill.leadingAnchor.constraint(equalTo: countdownTrack.leadingAnchor),
            countdownFill.topAnchor.constraint(equalTo: countdownTrack.topAnchor),
            countdownFill.bottomAnchor.constraint(equalTo: countdownTrack.bottomAnchor),
            width,
        ])

        let wrapper = UIStackView(arrangedSubviews: [countdownTrack])
        wrapper.axis = .vertical
        wrapper.isLayoutMarginsRelativeArrangement = true
        wrapper.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8)
        return wrapper
    }

    @objc private func done() {
        guard !didFinish else { return }
        didFinish = true
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
        var uploading = 0
        var failure: String?
        let record: (Result<ShareDirectUploader.Outcome?, Error>) -> Void = { result in
            lock.lock()
            defer { lock.unlock() }
            switch result {
            case .success(let outcome):
                saved += 1
                if outcome == .uploading { uploading += 1 }
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
                record(result.map { nil })
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
                self?.finish(failure: "Saved \(saved). One item could not be saved: \(failure)", title: "Not everything saved")
            } else {
                self?.finishSuccessfully(uploadStarted: uploading > 0)
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
        completion: @escaping (Result<ShareDirectUploader.Outcome?, Error>) -> Void
    ) {
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { temporaryURL, error in
            guard let temporaryURL else {
                completion(.failure(error ?? CocoaError(.fileReadUnknown)))
                return
            }
            // File representations are temporary. Copy before returning from
            // this callback and before telling iOS the share is done.
            do {
                let inbox = try ShareInboxStore()
                let uploader = Self.directUploader(inbox: inbox)
                let item = try inbox.stageFile(
                    from: temporaryURL,
                    originalName: provider.suggestedName ?? temporaryURL.lastPathComponent,
                    contentTypeExtension: UTType(typeIdentifier)?.preferredFilenameExtension,
                    reservingDirectUploadFor: uploader?.eligibleOwnerID()
                )
                guard let uploader, item.directUpload != nil else {
                    completion(.success(nil))
                    return
                }
                // The share is already safe, so nothing below can fail it.
                Task {
                    completion(.success(await uploader.start(item)))
                }
            } catch {
                completion(.failure(error))
            }
        }
    }

    private static func directUploader(inbox: ShareInboxStore) -> ShareDirectUploader? {
        guard let policy = try? ShareUploadPolicyFileStore() else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = ShareDirectUpload.presignTimeout
        configuration.timeoutIntervalForResource = ShareDirectUpload.presignTimeout
        let http = URLSession(configuration: configuration)
        let credentials = ShareUploadKeychainStore()
        return ShareDirectUploader(
            inbox: inbox,
            credentials: credentials,
            policy: policy,
            http: http,
            starter: ShareBackgroundUploadStarter { metadata, statusCode in
                guard let inbox = try? ShareInboxStore(),
                      let policy = try? ShareUploadPolicyFileStore()
                else { return }
                await ShareDirectUploader(
                    inbox: inbox,
                    credentials: credentials,
                    policy: policy,
                    http: http,
                    starter: ShareInertUploadStarter()
                ).finishTransfer(metadata, statusCode: statusCode)
            }
        )
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

    private func finishSuccessfully(uploadStarted: Bool) {
        showStatus(systemImage: "checkmark", tint: UIColor.ledger("on-accent"), background: UIColor.ledger("accent-fill"))
        titleLabel.text = "Saved to your library"
        noteLabel.text = uploadStarted
            ? "Uploading in the background."
            : "Saved on this iPhone for Media Tools to finish."
        noteLabel.isHidden = false
        closeButton.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: "\(titleLabel.text ?? "") \(noteLabel.text ?? "")")
        runCountdown()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.successDismissDelay) { [weak self] in
            self?.done()
        }
    }

    /// A failure stays on screen until dismissed because nothing was saved and
    /// the person needs to know that. It stays in ink: red means recording here too.
    private func finish(failure message: String, title: String = "Not saved") {
        showStatus(systemImage: "exclamationmark", tint: UIColor.ledger("text"), background: UIColor.ledger("fill"))
        titleLabel.text = title
        noteLabel.text = message
        noteLabel.textColor = UIColor.ledger("text")
        noteLabel.isHidden = false
        closeButton.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: "\(title) \(message)")
    }

    private func showStatus(systemImage: String, tint: UIColor, background: UIColor) {
        activity.stopAnimating()
        statusMark.image = UIImage(systemName: systemImage)
        statusMark.tintColor = tint
        statusBackground.backgroundColor = background
    }

    private func runCountdown() {
        guard !UIAccessibility.isReduceMotionEnabled, let countdownWidth else { return }
        countdownTrack.isHidden = false
        view.layoutIfNeeded()
        countdownWidth.isActive = false
        let empty = countdownFill.widthAnchor.constraint(equalToConstant: 0)
        empty.isActive = true
        UIView.animate(withDuration: Self.successDismissDelay, delay: 0, options: .curveLinear) {
            self.countdownTrack.layoutIfNeeded()
        }
    }
}

/// Nothing starts while finishing a transfer. The uploader only needs a value here.
private struct ShareInertUploadStarter: ShareBackgroundUploadStarting {
    func start(fileURL: URL, uploadURL: URL, metadata: BackgroundUploadMetadata, sessionIdentifier: String) throws {}
}
