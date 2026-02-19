import Foundation

extension URL {
    /// Check if this URL is a supported video URL for transcription.
    var isVideoURL: Bool {
        guard let host = host?.lowercased() else { return false }
        let videoHosts = [
            "youtube.com", "www.youtube.com", "youtu.be", "m.youtube.com",
            "vimeo.com", "www.vimeo.com", "player.vimeo.com",
            "dailymotion.com", "www.dailymotion.com",
        ]
        return videoHosts.contains(host) || pathExtension.lowercased().matches(videoExtensions)
    }

    /// Check if this URL points to an audio file.
    var isAudioURL: Bool {
        let audioExts = ["mp3", "m4a", "wav", "aac", "ogg", "flac", "wma"]
        return audioExts.contains(pathExtension.lowercased())
    }

    /// Check if this URL points to a PDF.
    var isPDFURL: Bool {
        pathExtension.lowercased() == "pdf"
    }

    private var videoExtensions: [String] {
        ["mp4", "mov", "avi", "mkv", "webm", "m4v"]
    }
}

private extension String {
    func matches(_ list: [String]) -> Bool {
        list.contains(self)
    }
}
