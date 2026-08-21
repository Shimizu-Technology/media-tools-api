import Foundation

enum RecordingIntegrityError: LocalizedError, Equatable {
    case emptyFile
    case malformedContainer
    case unfinalizedContainer

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "The saved recording is empty."
        case .malformedContainer:
            return "The saved recording has an invalid audio container."
        case .unfinalizedContainer:
            return "The recording stopped before its audio container was finalized."
        }
    }
}

/// Performs the structural check needed before an ISO media recording can be
/// offered for upload. AVAudioRecorder writes the `moov` box only when it
/// successfully finalizes an M4A. A non-empty file without that box contains
/// audio bytes but is not seekable or decodable by AVFoundation or ffmpeg.
enum RecordingIntegrityValidator {
    private static let isoMediaExtensions: Set<String> = ["m4a", "mp4", "mov"]

    static func validate(url: URL) -> Result<Void, RecordingIntegrityError> {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize,
              fileSize > 0
        else {
            return .failure(.emptyFile)
        }

        guard isoMediaExtensions.contains(url.pathExtension.lowercased()) else {
            return .success(())
        }

        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            let length = UInt64(fileSize)
            var offset: UInt64 = 0
            var foundMediaData = false
            var foundMovieMetadata = false

            while offset < length {
                guard length - offset >= 8 else {
                    return .failure(.malformedContainer)
                }
                try handle.seek(toOffset: offset)
                guard let header = try handle.read(upToCount: 8), header.count == 8 else {
                    return .failure(.malformedContainer)
                }

                var boxSize = readBigEndianInteger(header.prefix(4))
                let boxType = String(data: header.suffix(4), encoding: .ascii) ?? ""
                var headerSize: UInt64 = 8

                if boxSize == 1 {
                    guard length - offset >= 16,
                          let extended = try handle.read(upToCount: 8),
                          extended.count == 8
                    else {
                        return .failure(.malformedContainer)
                    }
                    boxSize = readBigEndianInteger(extended)
                    headerSize = 16
                } else if boxSize == 0 {
                    boxSize = length - offset
                }

                guard boxSize >= headerSize, boxSize <= length - offset else {
                    return .failure(.malformedContainer)
                }
                if boxType == "mdat", boxSize > headerSize {
                    foundMediaData = true
                } else if boxType == "moov", boxSize > headerSize {
                    foundMovieMetadata = true
                }
                offset += boxSize
            }

            guard foundMediaData, foundMovieMetadata else {
                return .failure(.unfinalizedContainer)
            }
            return .success(())
        } catch {
            return .failure(.malformedContainer)
        }
    }

    private static func readBigEndianInteger<S: Sequence>(_ bytes: S) -> UInt64
    where S.Element == UInt8 {
        bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
