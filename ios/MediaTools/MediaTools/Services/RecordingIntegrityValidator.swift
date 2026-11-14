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
///
/// The check answers only "did the writer finish?", not "can this be decoded?".
/// Shared and imported files come from other apps, and the server decodes every
/// upload with ffmpeg before transcribing, keeping the device copy when it can't.
enum RecordingIntegrityValidator {
    private static let isoMediaExtensions: Set<String> = ["m4a", "mp4", "mov"]

    static func validate(url: URL) -> Result<Void, RecordingIntegrityError> {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize,
              fileSize > 0
        else {
            return .failure(.emptyFile)
        }

        let pathExtension = url.pathExtension.lowercased()
        if pathExtension == "caf" {
            return validateCAF(url: url, fileSize: fileSize)
        }

        guard isoMediaExtensions.contains(pathExtension) else {
            return .success(())
        }

        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            let length = UInt64(fileSize)
            var offset: UInt64 = 0
            var foundMediaData = false
            var foundMovieMetadata = false

            // Once the audio and its index are both present, the writer finished.
            // Voice Memos can leave a few stale bytes after its last box when it
            // rewrites a memo's metadata in place, and every decoder ignores data
            // past the last box, so such a tail is not a reason to refuse the file.
            func malformedUnlessFinalized() -> Result<Void, RecordingIntegrityError> {
                foundMediaData && foundMovieMetadata ? .success(()) : .failure(.malformedContainer)
            }

            while offset < length {
                guard length - offset >= 8 else {
                    return malformedUnlessFinalized()
                }
                try handle.seek(toOffset: offset)
                guard let header = try handle.read(upToCount: 8), header.count == 8 else {
                    return malformedUnlessFinalized()
                }

                var boxSize = readBigEndianInteger(header.prefix(4))
                let boxType = String(data: header.suffix(4), encoding: .ascii) ?? ""
                var headerSize: UInt64 = 8

                // ISO box types are four printable characters. A file that does not
                // open with one has the wrong extension, such as raw AAC saved as
                // `.m4a`, and whether that decodes is for the server's ffmpeg to say.
                // Zeros are what a capture that never flushed leaves, so they are
                // still judged here.
                if offset == 0,
                   !header.allSatisfy({ $0 == 0 }),
                   !header.suffix(4).allSatisfy({ (0x20...0x7e).contains($0) }) {
                    return .success(())
                }

                // QuickTime allows more than one `mdat`, and a fragmented file adds
                // a `moof` per fragment, so a cut-off media box is missing media
                // even after the audio and its index were already seen.
                let cutOffResult = ["mdat", "moov", "moof"].contains(boxType)
                    ? .failure(.malformedContainer)
                    : malformedUnlessFinalized()

                if boxSize == 1 {
                    guard length - offset >= 16,
                          let extended = try handle.read(upToCount: 8),
                          extended.count == 8
                    else {
                        return cutOffResult
                    }
                    boxSize = readBigEndianInteger(extended)
                    headerSize = 16
                } else if boxSize == 0 {
                    boxSize = length - offset
                }

                guard boxSize >= headerSize, boxSize <= length - offset else {
                    return cutOffResult
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

    /// Validates the subset of Core Audio Format needed for durable capture.
    /// A CAF data chunk may legally use an all-ones size while recording; in
    /// that case the data continues through EOF and remains decodable after an
    /// unexpected process termination.
    private static func validateCAF(
        url: URL,
        fileSize: Int
    ) -> Result<Void, RecordingIntegrityError> {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            guard let header = try handle.read(upToCount: 8),
                  header.count == 8,
                  String(data: header.prefix(4), encoding: .ascii) == "caff",
                  readBigEndianInteger(header[4..<6]) == 1
            else {
                return .failure(.malformedContainer)
            }

            let length = UInt64(fileSize)
            var offset: UInt64 = 8
            var foundAudioDescription = false
            var foundAudioData = false

            while offset < length {
                guard length - offset >= 12 else {
                    return .failure(.malformedContainer)
                }
                try handle.seek(toOffset: offset)
                guard let chunkHeader = try handle.read(upToCount: 12),
                      chunkHeader.count == 12
                else {
                    return .failure(.malformedContainer)
                }

                let chunkType = String(data: chunkHeader.prefix(4), encoding: .ascii) ?? ""
                let chunkSize = readBigEndianInteger(chunkHeader.suffix(8))
                let payloadOffset = offset + 12

                if chunkSize == UInt64.max {
                    // CAF only permits an unknown size for the final audio-data
                    // chunk. Four bytes are the edit count; at least one audio
                    // byte must follow it before the recording is uploadable.
                    guard chunkType == "data", length > payloadOffset + 4 else {
                        return .failure(.malformedContainer)
                    }
                    foundAudioData = true
                    offset = length
                    continue
                }

                guard chunkSize <= length - payloadOffset else {
                    return .failure(.malformedContainer)
                }
                if chunkType == "desc", chunkSize >= 32 {
                    foundAudioDescription = true
                } else if chunkType == "data", chunkSize > 4 {
                    foundAudioData = true
                }
                offset = payloadOffset + chunkSize
            }

            guard foundAudioDescription, foundAudioData else {
                return .failure(.unfinalizedContainer)
            }
            return .success(())
        } catch {
            return .failure(.malformedContainer)
        }
    }
}
