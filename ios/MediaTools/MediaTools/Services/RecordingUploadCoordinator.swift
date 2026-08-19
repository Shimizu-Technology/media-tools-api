import Foundation
import Observation
import UniformTypeIdentifiers

/// Durable orchestration for recordings after capture finishes.
///
/// The recording manifest is the source of truth until the API creates its
/// transcription job. A separate watch manifest then follows server processing
/// so completion can still be delivered after the local audio is removed.
@MainActor
@Observable
final class RecordingUploadCoordinator: BackgroundUploadEventReceiving {
    static let shared = RecordingUploadCoordinator()

    private(set) var latestItem: AudioTranscription?
    private(set) var statusMessage: String?

    var latestItemSignature: String {
        guard let latestItem else { return "" }
        return [
            latestItem.id,
            latestItem.status,
            latestItem.processingStage ?? "",
            String(latestItem.processingProgress ?? -1),
        ].joined(separator: ":")
    }

    private let recorder: RecordingCoordinator
    private let service: MediaToolsService
    private let transport: BackgroundUploadService
    private let watchStore: TranscriptionWatchStore?
    private var watches: [TranscriptionWatch] = []
    private var uploadTasks: [UUID: Task<Void, Never>] = [:]
    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    private var watchTasks: [String: Task<Void, Never>] = [:]
    private var retryAttempts: [UUID: Int] = [:]
    private var hasReconciledTransfers = false
    private let simulatesUpload: Bool

    init(
        recorder: RecordingCoordinator? = nil,
        service: MediaToolsService = .shared,
        transport: BackgroundUploadService = .shared,
        watchStore: TranscriptionWatchStore? = nil
    ) {
        self.recorder = recorder ?? .shared
        self.service = service
        self.transport = transport
        if let watchStore {
            self.watchStore = watchStore
        } else {
            self.watchStore = try? TranscriptionWatchStore()
        }
        #if DEBUG
        simulatesUpload = ProcessInfo.processInfo.arguments.contains("-ui-test-simulated-upload")
        #else
        simulatesUpload = false
        #endif
        watches = (try? self.watchStore?.load()) ?? []
        transport.receiver = self
    }

    func queue(_ recording: LocalRecording) {
        guard !recording.isUploadInProgress else { return }
        recorder.markWaitingForUpload(recording.id)
        retryAttempts[recording.id] = 0
        process(recordingID: recording.id)
    }

    func resumePendingWork() {
        transport.receiver = self
        for watch in watches {
            startWatching(watch)
        }

        for recording in recorder.pendingRecordings {
            switch recording.state {
            case .waitingForUpload:
                process(recordingID: recording.id)
            case .finalizingUpload:
                finalize(recordingID: recording.id)
            default:
                break
            }
        }

        guard !hasReconciledTransfers else { return }
        hasReconciledTransfers = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            let activeIDs = await self.transport.activeRecordingIDs()
            for recording in self.recorder.pendingRecordings
            where recording.state == .uploading && !activeIDs.contains(recording.id) {
                self.recorder.markWaitingForUpload(
                    recording.id,
                    message: "The interrupted upload will resume automatically."
                )
                self.process(recordingID: recording.id)
            }
        }
    }

    func receiveBackgroundUploadEvent(_ event: BackgroundUploadEvent) {
        switch event {
        case .progress(let metadata, let fractionCompleted):
            recorder.updateUploadProgress(metadata.recordingID, progress: fractionCompleted)
        case .completed(let metadata):
            retryTasks[metadata.recordingID]?.cancel()
            retryTasks[metadata.recordingID] = nil
            recorder.markUploadFinalizing(metadata.recordingID)
            finalize(recordingID: metadata.recordingID)
        case .failed(let metadata, let message, let shouldRetry):
            if shouldRetry {
                recorder.markWaitingForUpload(
                    metadata.recordingID,
                    message: "Upload paused. Media Tools will retry automatically."
                )
                scheduleRetry(recordingID: metadata.recordingID)
            } else {
                recorder.markUploadFailed(metadata.recordingID, message: message)
                statusMessage = message
            }
        }
    }

    private func process(recordingID: UUID) {
        guard uploadTasks[recordingID] == nil,
              let recording = recorder.recording(withID: recordingID),
              recording.state == .waitingForUpload || recording.state == .uploadFailed,
              let fileURL = recorder.fileURL(for: recording)
        else { return }

        uploadTasks[recordingID] = Task { [weak self] in
            guard let self else { return }
            defer { self.uploadTasks[recordingID] = nil }
            if self.simulatesUpload {
                await self.simulateUpload(recording: recording)
                return
            }
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                guard let size = attributes[.size] as? NSNumber, size.int64Value > 0 else {
                    throw APIError.invalidFile(message: "The saved recording is empty.")
                }
                let mimeType = Self.mimeType(for: fileURL)
                let presign = try await self.service.presignAudioUpload(
                    filename: recording.uploadFilename,
                    mimeType: mimeType,
                    sizeBytes: size.int64Value
                )
                let metadata = BackgroundUploadMetadata(
                    recordingID: recording.id,
                    filename: recording.uploadFilename,
                    objectKey: presign.objectKey,
                    sizeBytes: size.int64Value,
                    mimeType: mimeType,
                    contentType: recording.contentType
                )
                try self.transport.enqueue(
                    fileURL: fileURL,
                    uploadURL: presign.uploadUrl,
                    metadata: metadata
                ) { taskIdentifier in
                    self.recorder.markUploadStarted(
                        recording.id,
                        objectKey: presign.objectKey,
                        sizeBytes: size.int64Value,
                        mimeType: mimeType,
                        taskIdentifier: taskIdentifier
                    )
                }
                self.retryAttempts[recordingID] = 0
                self.statusMessage = "Uploading in the background"
            } catch let apiError as APIError where apiError.permitsMultipartUploadFallback {
                await self.performForegroundFallback(recordingID: recordingID, fileURL: fileURL)
            } catch {
                self.handlePreparationFailure(error, recordingID: recordingID)
            }
        }
    }

    private func performForegroundFallback(recordingID: UUID, fileURL: URL) async {
        guard let recording = recorder.recording(withID: recordingID) else { return }
        do {
            let item = try await service.uploadAudio(
                fileURL: fileURL,
                filename: recording.uploadFilename,
                mimeType: Self.mimeType(for: fileURL),
                contentType: recording.contentType
            )
            accept(item: item, recordingID: recordingID)
        } catch {
            handlePreparationFailure(error, recordingID: recordingID)
        }
    }

    private func finalize(recordingID: UUID) {
        guard uploadTasks[recordingID] == nil,
              let recording = recorder.recording(withID: recordingID),
              recording.state == .finalizingUpload,
              let objectKey = recording.uploadObjectKey,
              let sizeBytes = recording.uploadSizeBytes
        else { return }

        uploadTasks[recordingID] = Task { [weak self] in
            guard let self else { return }
            defer { self.uploadTasks[recordingID] = nil }
            do {
                let item = try await self.service.completeAudioUpload(
                    AudioUploadCompleteRequest(
                        objectKey: objectKey,
                        originalName: recording.uploadFilename,
                        sizeBytes: sizeBytes,
                        contentType: recording.contentType
                    )
                )
                self.accept(item: item, recordingID: recordingID)
            } catch {
                if Self.isRetryableFinalization(error) {
                    self.statusMessage = "Upload is safe. Finishing will retry automatically."
                    self.scheduleRetry(recordingID: recordingID, finalizing: true)
                } else {
                    self.recorder.markUploadFailed(recordingID, message: error.localizedDescription)
                    self.statusMessage = error.localizedDescription
                }
            }
        }
    }

    private func accept(item: AudioTranscription, recordingID: UUID) {
        guard let recording = recorder.recording(withID: recordingID) else { return }
        recorder.markUploaded(recording)
        retryAttempts[recordingID] = nil
        retryTasks[recordingID]?.cancel()
        retryTasks[recordingID] = nil
        latestItem = item
        statusMessage = "Upload complete. Transcription is processing."
        let watch = TranscriptionWatch(
            id: item.id,
            title: item.displayTitle,
            createdAt: Date()
        )
        addWatch(watch)
        startWatching(watch)
        NotificationService.notifyAudioUploadAccepted(title: item.displayTitle, itemId: item.id)
    }

    private func addWatch(_ watch: TranscriptionWatch) {
        watches.removeAll { $0.id == watch.id }
        watches.append(watch)
        persistWatches()
    }

    private func startWatching(_ watch: TranscriptionWatch) {
        guard watchTasks[watch.id] == nil else { return }
        watchTasks[watch.id] = Task { [weak self] in
            guard let self else { return }
            defer { self.watchTasks[watch.id] = nil }
            if self.simulatesUpload {
                try? await Task.sleep(for: .seconds(1))
                guard let item = self.simulatedItem(
                    id: watch.id,
                    title: watch.title,
                    status: "completed",
                    stage: "completed",
                    progress: 100
                ) else { return }
                self.latestItem = item
                self.removeWatch(id: watch.id)
                self.statusMessage = "Transcription complete"
                return
            }
            var failures = 0
            while !Task.isCancelled {
                do {
                    let item = try await self.service.getAudioItem(watch.id)
                    failures = 0
                    self.latestItem = item
                    if item.status == "completed" {
                        self.removeWatch(id: watch.id)
                        self.statusMessage = "Transcription complete"
                        NotificationService.notifyAudioComplete(
                            title: item.displayTitle,
                            itemId: item.id
                        )
                        return
                    }
                    if item.status == "failed" {
                        self.removeWatch(id: watch.id)
                        self.statusMessage = item.errorMessage ?? "Transcription failed"
                        NotificationService.notifyAudioFailed(
                            title: item.displayTitle,
                            itemId: item.id
                        )
                        return
                    }
                    try await Task.sleep(for: .seconds(5))
                } catch is CancellationError {
                    return
                } catch {
                    failures += 1
                    if failures >= 3 { return }
                    try? await Task.sleep(for: .seconds(5 * failures))
                }
            }
        }
    }

    private func removeWatch(id: String) {
        watches.removeAll { $0.id == id }
        persistWatches()
    }

    private func persistWatches() {
        do {
            try watchStore?.save(watches)
        } catch {
            statusMessage = "Completion alerts could not be saved. Check Library for status."
        }
    }

    private func handlePreparationFailure(_ error: Error, recordingID: UUID) {
        if Self.isRetryable(error) {
            recorder.markWaitingForUpload(
                recordingID,
                message: "Waiting for a connection. Media Tools will retry automatically."
            )
            scheduleRetry(recordingID: recordingID)
        } else {
            recorder.markUploadFailed(recordingID, message: error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }

    private func scheduleRetry(recordingID: UUID, finalizing: Bool = false) {
        guard retryTasks[recordingID] == nil else { return }
        let attempt = (retryAttempts[recordingID] ?? 0) + 1
        retryAttempts[recordingID] = attempt
        let delay = min(pow(2, Double(attempt - 1)) * 2, 60)
        retryTasks[recordingID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.retryTasks[recordingID] = nil
            if finalizing {
                self.finalize(recordingID: recordingID)
            } else {
                self.process(recordingID: recordingID)
            }
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if let apiError = error as? APIError { return apiError.isRetryable }
        if error is URLError { return true }
        return false
    }

    private static func isRetryableFinalization(_ error: Error) -> Bool {
        if let apiError = error as? APIError {
            if case .httpError(let statusCode, _, _) = apiError, statusCode == 401 {
                // A background URLSession wake-up can arrive before Clerk finishes
                // restoring its session. The object is already safe, so preserve
                // finalization and try again when authentication is available.
                return true
            }
        }
        return isRetryable(error)
    }

    private static func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
    }

    private func simulateUpload(recording: LocalRecording) async {
        recorder.markUploadStarted(
            recording.id,
            objectKey: "ui-test/\(recording.filename)",
            sizeBytes: 42,
            mimeType: "audio/mp4",
            taskIdentifier: 1
        )
        for progress in [0.2, 0.55, 0.85] {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            recorder.updateUploadProgress(recording.id, progress: progress)
        }
        recorder.markUploadFinalizing(recording.id)
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        guard let item = simulatedItem(
            id: "ui-test-audio",
            title: recording.displayTitle,
            status: "pending",
            stage: "queued",
            progress: 0
        ) else {
            recorder.markUploadFailed(recording.id, message: "UI test fixture could not be created.")
            return
        }
        accept(item: item, recordingID: recording.id)
    }

    private func simulatedItem(
        id: String,
        title: String,
        status: String,
        stage: String,
        progress: Int
    ) -> AudioTranscription? {
        let payload: [String: Any] = [
            "id": id,
            "title": title,
            "status": status,
            "processing_stage": stage,
            "processing_progress": progress,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return try? APIClient.makeDecoder().decode(AudioTranscription.self, from: data)
    }
}
