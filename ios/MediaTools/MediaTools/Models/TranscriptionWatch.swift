import Foundation

struct TranscriptionWatch: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let title: String
    let createdAt: Date
    var authenticationPausedAt: Date? = nil
}

/// Keeps the tiny amount of metadata required to deliver a completion
/// notification after the source recording has safely left the device.
struct TranscriptionWatchStore {
    private struct Manifest: Codable {
        let version: Int
        var watches: [TranscriptionWatch]
    }

    private let fileURL: URL

    init(rootDirectory: URL? = nil) throws {
        let directory: URL
        if let rootDirectory {
            directory = rootDirectory
        } else {
            let applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            directory = applicationSupport.appendingPathComponent("MediaTools", isDirectory: true)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        fileURL = directory.appendingPathComponent("transcription-watches.json")
    }

    func load() throws -> [TranscriptionWatch] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let manifest = try Self.decoder.decode(Manifest.self, from: data)
        guard manifest.version == 1 else { throw CocoaError(.coderReadCorrupt) }
        return manifest.watches
    }

    func save(_ watches: [TranscriptionWatch]) throws {
        let data = try Self.encoder.encode(Manifest(version: 1, watches: watches))
        try data.write(
            to: fileURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
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
