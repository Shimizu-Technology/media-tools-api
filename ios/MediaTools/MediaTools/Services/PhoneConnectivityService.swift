import Foundation
import WatchConnectivity

/// iPhone-side WatchConnectivity handler.
/// Receives audio files from Watch, uploads to API, sends status updates back.
final class PhoneConnectivityService: NSObject, ObservableObject {
    static let shared = PhoneConnectivityService()

    @Published var lastWatchTranscriptionId: String?
    @Published var isProcessingWatchAudio = false

    private let service = MediaToolsService.shared

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    /// Send recent items to the Watch for display.
    func syncRecentItems() {
        guard WCSession.default.isReachable else { return }

        let items = service.transcripts.prefix(5).map { t -> [String: Any] in
            [
                WatchMessage.idKey: t.id,
                WatchMessage.titleKey: t.displayTitle,
                WatchMessage.statusKey: t.status,
                WatchMessage.wordCountKey: t.wordCount ?? 0,
            ]
        }

        try? WCSession.default.updateApplicationContext([
            WatchMessage.typeKey: WatchMessage.recentItems,
            "items": Array(items),
            WatchMessage.timestampKey: Date().timeIntervalSince1970,
        ])
    }

    /// Send transcription status update to Watch.
    private func sendStatusToWatch(id: String, status: String, title: String, wordCount: Int = 0) {
        guard WCSession.default.isReachable else {
            // Fall back to application context (delivered when Watch wakes)
            try? WCSession.default.updateApplicationContext([
                WatchMessage.typeKey: WatchMessage.transcriptionUpdate,
                WatchMessage.idKey: id,
                WatchMessage.statusKey: status,
                WatchMessage.titleKey: title,
                WatchMessage.wordCountKey: wordCount,
            ])
            return
        }

        WCSession.default.sendMessage([
            WatchMessage.typeKey: WatchMessage.transcriptionUpdate,
            WatchMessage.idKey: id,
            WatchMessage.statusKey: status,
            WatchMessage.titleKey: title,
            WatchMessage.wordCountKey: wordCount,
        ], replyHandler: nil)
    }

    /// Process received audio from Watch.
    private func processWatchAudio(fileURL: URL, metadata: [String: Any]) async {
        isProcessingWatchAudio = true
        defer { isProcessingWatchAudio = false }

        let filename = metadata[WatchMessage.filenameKey] as? String ?? "watch-recording.m4a"
        let contentType = metadata[WatchMessage.contentTypeKey] as? String ?? "voice_memo"

        do {
            // Copy file to a stable location (WC files are temporary)
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("m4a")
            try FileManager.default.copyItem(at: fileURL, to: tempURL)

            let data = try Data(contentsOf: tempURL)

            // Upload to API
            let result: AudioTranscription = try await APIClient.shared.upload(
                "/audio/transcriptions",
                fileData: data,
                filename: filename,
                mimeType: "audio/m4a",
                fields: ["content_type": contentType]
            )

            lastWatchTranscriptionId = result.id

            // Notify Watch: upload accepted
            sendStatusToWatch(
                id: result.id,
                status: WatchMessage.statusProcessing,
                title: result.displayTitle
            )

            // Poll for completion
            var current = result
            while current.status != "completed" && current.status != "failed" {
                try await Task.sleep(for: .seconds(5))
                current = try await service.getAudioItem(current.id)

                sendStatusToWatch(
                    id: current.id,
                    status: current.status,
                    title: current.displayTitle,
                    wordCount: current.wordCount ?? 0
                )
            }

            // Final notification
            if current.status == "completed" {
                NotificationService.notifyAudioComplete(
                    title: "Watch Recording: \(current.displayTitle)",
                    itemId: current.id
                )
                await service.loadAudioItems()
                syncRecentItems()
            }

            // Cleanup
            try? FileManager.default.removeItem(at: tempURL)

        } catch {
            print("Watch audio processing failed: \(error)")
            sendStatusToWatch(
                id: "",
                status: WatchMessage.statusFailed,
                title: "Upload failed: \(error.localizedDescription)"
            )
        }
    }
}

// MARK: - WCSessionDelegate

extension PhoneConnectivityService: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            print("WCSession activation failed: \(error)")
        } else {
            print("WCSession activated: \(activationState.rawValue)")
            // Sync recent items when Watch connects
            Task { @MainActor in
                syncRecentItems()
            }
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate for Watch switching
        session.activate()
    }

    // MARK: - Receive Files from Watch

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let metadata = file.metadata ?? [:]
        let fileURL = file.fileURL

        Task { @MainActor in
            await processWatchAudio(fileURL: fileURL, metadata: metadata)
        }
    }

    // MARK: - Receive Messages from Watch

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let type = message[WatchMessage.typeKey] as? String

        switch type {
        case WatchMessage.requestStatus:
            // Watch is asking for current status
            let items = service.transcripts.prefix(5).map { t -> [String: Any] in
                [
                    WatchMessage.idKey: t.id,
                    WatchMessage.titleKey: t.displayTitle,
                    WatchMessage.statusKey: t.status,
                    WatchMessage.wordCountKey: t.wordCount ?? 0,
                ]
            }
            replyHandler([
                WatchMessage.typeKey: WatchMessage.recentItems,
                "items": Array(items),
            ])

        default:
            replyHandler(["status": "unknown_message"])
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        // Fire-and-forget messages
    }
}
