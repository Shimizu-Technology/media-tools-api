import Foundation

/// A file-based handoff between the share extension and the app. Each share has
/// its own directory so an extension ending mid-copy cannot publish a partial
/// recording, and concurrent shares never rewrite one shared manifest.
struct ShareInboxStore {
    // Keep this list in sync with the API's audio upload allowlist. A share
    // should never appear ready to transcribe if upload will reject it.
    static let supportedExtensions: Set<String> = [
        "mp3", "wav", "caf", "m4a", "mp4", "ogg", "flac", "webm",
    ]

    enum ShareError: LocalizedError {
        case unsupportedFormat
        case fileTooLarge

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                "This file format cannot be transcribed. Share an MP3, WAV, CAF, M4A, MP4, OGG, FLAC, or WebM file."
            case .fileTooLarge:
                "This file is larger than the 2 GB upload limit."
            }
        }
    }

    struct Item: Codable, Identifiable {
        let id: UUID
        let originalName: String
        let storedName: String
        let createdAt: Date
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

    func stageFile(from sourceURL: URL, originalName: String) throws -> Item {
        let id = UUID()
        let directory = directoryURL(for: id)
        let safeName = (originalName as NSString).lastPathComponent
        let sourceExtension = sourceURL.pathExtension.lowercased()
        let displayExtension = (safeName as NSString).pathExtension.lowercased()
        let fileExtension = !displayExtension.isEmpty ? displayExtension : sourceExtension
        guard Self.supportedExtensions.contains(fileExtension) else {
            throw ShareError.unsupportedFormat
        }
        if let size = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           Int64(size) > 2 * 1_024 * 1_024 * 1_024 {
            throw ShareError.fileTooLarge
        }
        let storedName = fileExtension.isEmpty ? "source" : "source.\(fileExtension)"
        let displayName = safeName.isEmpty ? storedName : (
            displayExtension.isEmpty && !fileExtension.isEmpty
                ? "\(safeName).\(fileExtension)"
                : safeName
        )
        let item = Item(
            id: id,
            originalName: displayName,
            storedName: storedName,
            createdAt: Date()
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
            let manifest = try JSONEncoder().encode(item)
            try manifest.write(
                to: directory.appendingPathComponent("item.json"),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
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
                  item.storedName == "source.\((item.storedName as NSString).pathExtension.lowercased())",
                  Self.supportedExtensions.contains((item.storedName as NSString).pathExtension.lowercased()),
                  fileManager.fileExists(atPath: fileURL(for: item).path)
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

    private func directoryURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }
}
