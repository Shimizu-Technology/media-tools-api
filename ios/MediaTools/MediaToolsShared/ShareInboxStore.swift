import Foundation

/// A file-based handoff between the share extension and the app. Each share has
/// its own directory so an extension ending mid-copy cannot publish a partial
/// recording, and concurrent shares never rewrite one shared manifest.
struct ShareInboxStore {
    // Keep this list in sync with the API's audio upload allowlist. A share
    // should never appear ready to transcribe if upload will reject it.
    static let supportedAudioExtensions: Set<String> = [
        "mp3", "wav", "caf", "m4a", "mp4", "mov", "qta", "aac", "ogg", "flac", "webm",
    ]
    static let supportedExtensions = supportedAudioExtensions.union(["pdf"])
    private static let maximumPDFBytes: Int64 = 50 * 1_024 * 1_024
    private static let maximumAudioBytes: Int64 = 2 * 1_024 * 1_024 * 1_024

    enum ShareError: LocalizedError {
        case unsupportedFormat
        case fileTooLarge
        case pdfTooLarge
        case unsupportedLink

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                "This file format cannot be transcribed. Share an MP3, WAV, CAF, M4A, MP4, MOV, QTA, AAC, OGG, FLAC, WebM, or PDF file."
            case .fileTooLarge:
                "This file is larger than the 2 GB upload limit."
            case .pdfTooLarge:
                "This PDF is larger than the 50 MB upload limit."
            case .unsupportedLink:
                "Share a web link to a video."
            }
        }
    }

    enum Kind: String, Codable {
        case audio
        case pdf
        case link
    }

    struct Item: Codable, Identifiable {
        let id: UUID
        let originalName: String
        let storedName: String
        let createdAt: Date
        /// Older shares predate this field and were always audio.
        var kind: Kind? = nil
        var link: String? = nil
        /// The account this PDF or link belongs to. The extension cannot know who
        /// is signed in, so a share starts unowned and the first signed-in account
        /// claims it, the same way a signed-out recording is claimed.
        var ownerID: String? = nil
        /// Set when "Automatically transcribe" was on as the account claimed this
        /// share. A link claimed with it off keeps waiting for a deliberate tap.
        var autoTranscribeRequested: Bool? = nil

        var resolvedKind: Kind { kind ?? .audio }
    }

    let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            guard let container = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: "group.com.shimizu-technology.media-tools"
            ) else {
                throw CocoaError(.fileNoSuchFile)
            }
            self.rootURL = container.appendingPathComponent("ShareInbox", isDirectory: true)
        }
        try fileManager.createDirectory(
            at: self.rootURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = self.rootURL
        try mutableRoot.setResourceValues(values)
    }

    /// The source file's real extension wins over anything that looks like an
    /// extension in the display name, because "Call v2.1" is a name and not a
    /// `.1` file. The display name is the fallback for providers that hand over
    /// a temporary file, and the shared type covers names with no extension.
    static func resolvedExtension(
        sourceExtension: String,
        displayName: String,
        contentTypeExtension: String? = nil
    ) -> String? {
        let candidates = [
            sourceExtension,
            (displayName as NSString).pathExtension,
            contentTypeExtension ?? "",
        ]
        return candidates
            .map { $0.lowercased() }
            .first { supportedExtensions.contains($0) }
    }

    func stageFile(
        from sourceURL: URL,
        originalName: String,
        contentTypeExtension: String? = nil
    ) throws -> Item {
        let id = UUID()
        let directory = directoryURL(for: id)
        let safeName = (originalName as NSString).lastPathComponent
        guard let fileExtension = Self.resolvedExtension(
            sourceExtension: sourceURL.pathExtension,
            displayName: safeName,
            contentTypeExtension: contentTypeExtension
        ) else {
            throw ShareError.unsupportedFormat
        }
        let kind: Kind = fileExtension == "pdf" ? .pdf : .audio
        if let size = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            if kind == .pdf, Int64(size) > Self.maximumPDFBytes {
                throw ShareError.pdfTooLarge
            }
            if Int64(size) > Self.maximumAudioBytes {
                throw ShareError.fileTooLarge
            }
        }
        let storedName = "source.\(fileExtension)"
        let item = Item(
            id: id,
            originalName: Self.displayName(safeName, fileExtension: fileExtension, fallback: storedName),
            storedName: storedName,
            createdAt: Date(),
            kind: kind
        )

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        do {
            try fileManager.copyItem(at: sourceURL, to: fileURL(for: item))
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: fileURL(for: item).path
            )
            try writeManifest(item, in: directory)
            return item
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    /// Links have no file to copy. The app sends them to the server, which
    /// decides whether the page has a video it can transcribe.
    func stageLink(_ url: URL, title: String? = nil) throws -> Item {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host?.isEmpty == false
        else {
            throw ShareError.unsupportedLink
        }
        let id = UUID()
        let directory = directoryURL(for: id)
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = Item(
            id: id,
            originalName: trimmedTitle?.isEmpty == false ? trimmedTitle! : url.absoluteString,
            storedName: "link",
            createdAt: Date(),
            kind: .link,
            link: url.absoluteString
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        do {
            try writeManifest(item, in: directory)
            return item
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    func pendingItems() throws -> [Item] {
        let directories = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return directories.compactMap { directory in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("item.json")),
                  let item = try? JSONDecoder().decode(Item.self, from: data),
                  directory.lastPathComponent == item.id.uuidString.lowercased(),
                  isComplete(item)
            else { return nil }
            return item
        }.sorted { $0.createdAt < $1.createdAt }
    }

    func fileURL(for item: Item) -> URL {
        directoryURL(for: item.id).appendingPathComponent(item.storedName)
    }

    func remove(_ item: Item) throws {
        try fileManager.removeItem(at: directoryURL(for: item.id))
    }

    /// Saves a claim before anything is sent, so a relaunch can never hand this
    /// share to whichever account happens to be signed in next.
    func update(_ item: Item) throws {
        try writeManifest(item, in: directoryURL(for: item.id))
    }

    private func isComplete(_ item: Item) -> Bool {
        if item.resolvedKind == .link {
            return item.link.flatMap(URL.init(string:)) != nil
        }
        let fileExtension = (item.storedName as NSString).pathExtension.lowercased()
        return item.storedName == "source.\(fileExtension)"
            && Self.supportedExtensions.contains(fileExtension)
            && fileManager.fileExists(atPath: fileURL(for: item).path)
    }

    private func writeManifest(_ item: Item, in directory: URL) throws {
        let manifest = try JSONEncoder().encode(item)
        try manifest.write(
            to: directory.appendingPathComponent("item.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    /// Replace only a real file extension, so "Call v2.1" becomes
    /// "Call v2.1.m4a" rather than "Call v2.m4a".
    private static func displayName(
        _ name: String,
        fileExtension: String,
        fallback: String
    ) -> String {
        guard !name.isEmpty else { return fallback }
        let nameExtension = (name as NSString).pathExtension.lowercased()
        if nameExtension == fileExtension { return name }
        let base = supportedExtensions.contains(nameExtension)
            ? (name as NSString).deletingPathExtension
            : name
        return "\(base).\(fileExtension)"
    }

    private func directoryURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }
}
