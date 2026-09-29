import UIKit
import UniformTypeIdentifiers

/// Saves a shared file on-device. The main app handles account selection,
/// AI processing consent, upload, and retry after relaunch.
final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let activity = UIActivityIndicatorView(style: .medium)
    private let doneButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let symbol = UIImageView(image: UIImage(systemName: "waveform.circle.fill"))
        symbol.tintColor = .systemTeal
        symbol.contentMode = .scaleAspectFit
        symbol.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.text = "Saving to Media Tools on this iPhone…"
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        activity.startAnimating()
        activity.translatesAutoresizingMaskIntoConstraints = false

        doneButton.setTitle("Done", for: .normal)
        doneButton.addTarget(self, action: #selector(done), for: .touchUpInside)
        doneButton.isEnabled = false
        doneButton.translatesAutoresizingMaskIntoConstraints = false

        [symbol, statusLabel, activity, doneButton].forEach(view.addSubview)
        NSLayoutConstraint.activate([
            symbol.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -65),
            symbol.widthAnchor.constraint(equalToConstant: 54),
            symbol.heightAnchor.constraint(equalToConstant: 54),
            statusLabel.topAnchor.constraint(equalTo: symbol.bottomAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            activity.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
            activity.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            doneButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            doneButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
        saveOfferedFile()
    }

    @objc private func done() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func saveOfferedFile() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []
        guard let match = providers.lazy.compactMap({ provider -> (NSItemProvider, String)? in
            if provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
                return (provider, UTType.audio.identifier)
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                return (provider, UTType.movie.identifier)
            }
            return nil
        }).first else {
            finish("Share an audio or video file to save it in Media Tools.", success: false)
            return
        }

        let (provider, typeIdentifier) = match
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] temporaryURL, error in
            guard let self else { return }
            guard let temporaryURL else {
                self.finish(error?.localizedDescription ?? "This app did not provide a file to share.", success: false)
                return
            }
            do {
                // File representations are temporary. Copy before returning
                // from this callback and before telling iOS the share is done.
                let name = provider.suggestedName ?? temporaryURL.lastPathComponent
                let item = try ShareInboxStore().stageFile(from: temporaryURL, originalName: name)
                self.finish("Saved \(item.originalName) on this iPhone. Open Media Tools to review and transcribe it.", success: true)
            } catch {
                self.finish("Could not save this file: \(error.localizedDescription)", success: false)
            }
        }
    }

    private func finish(_ message: String, success: Bool) {
        DispatchQueue.main.async {
            self.activity.stopAnimating()
            self.statusLabel.text = message
            self.statusLabel.textColor = success ? .label : .systemRed
            self.doneButton.isEnabled = true
        }
    }
}
