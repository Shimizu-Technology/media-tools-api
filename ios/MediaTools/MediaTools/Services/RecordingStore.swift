import Foundation

enum RecordingStorageCapacity {
    /// Uses Apple's important-usage value because an in-progress recording is
    /// user-created data that needs enough headroom to finish safely.
    static func available(at directoryURL: URL) -> Int64? {
        try? directoryURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
    }
}

/// File-backed metadata and audio storage for recordings that have not yet been
/// accepted by the server. The JSON manifest is deliberately small and boring:
/// it is atomic, inspectable, and can be shared with system extensions through
/// an App Group in the next quick-capture phase.
struct RecordingStore {
    private struct Manifest: Codable {
        let version: Int
        var recordings: [LocalRecording]
    }

    let directoryURL: URL
    private let manifestURL: URL
    private let fileManager: FileManager

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager

        if let rootDirectory {
            directoryURL = rootDirectory
        } else {
            let applicationSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            directoryURL = applicationSupport
                .appendingPathComponent("MediaTools", isDirectory: true)
                .appendingPathComponent("Recordings", isDirectory: true)
        }
        manifestURL = directoryURL.appendingPathComponent("recordings.json")

        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDirectoryURL = directoryURL
        try mutableDirectoryURL.setResourceValues(resourceValues)
    }

    func loadRecordings() throws -> [LocalRecording] {
        guard fileManager.fileExists(atPath: manifestURL.path) else { return [] }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try Self.decoder.decode(Manifest.self, from: data)
        guard manifest.version == 1 else {
            throw CocoaError(.coderReadCorrupt)
        }
        return manifest.recordings
            .filter { fileManager.fileExists(atPath: fileURL(for: $0).path) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func saveRecordings(_ recordings: [LocalRecording]) throws {
        let manifest = Manifest(version: 1, recordings: recordings)
        let data = try Self.encoder.encode(manifest)
        try data.write(
            to: manifestURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    func makeRecording(contentType: String, now: Date = Date()) -> LocalRecording {
        let id = UUID()
        let recording = LocalRecording(
            id: id,
            filename: "\(id.uuidString.lowercased()).m4a",
            originalFilename: nil,
            createdAt: now,
            duration: 0,
            contentType: contentType,
            state: .recording,
            lastError: nil,
            uploadProgress: nil,
            uploadObjectKey: nil,
            uploadSizeBytes: nil,
            uploadMimeType: nil,
            uploadTaskIdentifier: nil
        )
        return recording
    }

    func importRecording(
        from sourceURL: URL,
        contentType: String,
        now: Date = Date()
    ) throws -> LocalRecording {
        let id = UUID()
        let sourceExtension = sourceURL.pathExtension.lowercased()
        let filename = sourceExtension.isEmpty
            ? "\(id.uuidString.lowercased()).audio"
            : "\(id.uuidString.lowercased()).\(sourceExtension)"
        let recording = LocalRecording(
            id: id,
            filename: filename,
            originalFilename: sourceURL.lastPathComponent,
            createdAt: now,
            duration: 0,
            contentType: contentType,
            state: .ready,
            lastError: nil,
            uploadProgress: nil,
            uploadObjectKey: nil,
            uploadSizeBytes: nil,
            uploadMimeType: nil,
            uploadTaskIdentifier: nil
        )
        try fileManager.copyItem(at: sourceURL, to: fileURL(for: recording))
        try protectRecordingFile(recording)
        return recording
    }

    func fileURL(for recording: LocalRecording) -> URL {
        directoryURL.appendingPathComponent(recording.filename, isDirectory: false)
    }

    func protectRecordingFile(_ recording: LocalRecording) throws {
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL(for: recording).path
        )
    }

    func deleteFile(for recording: LocalRecording) throws {
        let url = fileURL(for: recording)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func deleteAllRecordings() throws {
        let contents = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        for url in contents {
            try fileManager.removeItem(at: url)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
