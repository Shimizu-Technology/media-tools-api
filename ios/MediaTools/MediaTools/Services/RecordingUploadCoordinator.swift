import Foundation
import Observation
import UniformTypeIdentifiers

enum TranscriptionWatchFailureDisposition: Equatable {
    case retry
    case pauseForAuthentication
    case stop
}

/// Durable orchestration for recordings after capture finishes.
///
/// The recording manifest remains the source of truth until server processing
/// succeeds. A separate watch manifest links the remote job to its device copy
/// so a 202 response can never discard the only recoverable source recording.
@MainActor
@Observable
final class RecordingUploadCoordinator: BackgroundUploadEventReceiving {
    static let shared = RecordingUploadCoordinator()
    static let maximumAuthenticationPauseAge: TimeInterval = 30 * 24 * 60 * 60
    static let pendingLocalAccountDeletionOwnerIDsKey =
        "pendingLocalAccountDeletionOwnerIDs"

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
    private let localAccountDefaults: UserDefaults
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
        watchStore: TranscriptionWatchStore? = nil,
        localAccountDefaults: UserDefaults = .standard
    ) {
        self.recorder = recorder ?? .shared
        self.service = service
        self.transport = transport
        if let watchStore {
            self.watchStore = watchStore
        } else {
            self.watchStore = try? TranscriptionWatchStore()
        }
        self.localAccountDefaults = localAccountDefaults
        #if DEBUG
        simulatesUpload = ProcessInfo.processInfo.arguments.contains("-ui-test-simulated-upload")
        #else
        simulatesUpload = false
        #endif
        watches = (try? self.watchStore?.load()) ?? []
        transport.receiver = self
    }

    func queue(_ recording: LocalRecording) {
        guard recording.canUpload, recording.ownerID == recorder.activeOwnerID else { return }
        recorder.markWaitingForUpload(recording.id)
        retryAttempts[recording.id] = 0
        process(recordingID: recording.id)
    }

    /// Keeps upload/finalization credentials aligned with the signed-in Clerk
    /// account. Work owned by another account is paused instead of ever being
    /// finalized with the new account's bearer token.
    func setActiveOwnerID(_ ownerID: String?) async {
        await retryPendingLocalAccountDeletions()
        recorder.setActiveOwnerID(ownerID)
        if let ownerID {
            for index in watches.indices where watches[index].ownerID == nil {
                if let recordingID = watches[index].recordingID,
                   recorder.recording(withID: recordingID)?.ownerID != ownerID {
                    continue
                }
                watches[index].ownerID = ownerID
            }
        }

        let activeRecordingIDs = ownerID.map { recorder.recordingIDsOwned(by: $0) } ?? []
        let allRecordingIDs = Set(recorder.pendingRecordings.map(\.id))
        let pausedRecordingIDs = allRecordingIDs.subtracting(activeRecordingIDs)
        for recordingID in pausedRecordingIDs {
            uploadTasks[recordingID]?.cancel()
            uploadTasks[recordingID] = nil
            retryTasks[recordingID]?.cancel()
            retryTasks[recordingID] = nil
            retryAttempts[recordingID] = nil
        }
        await transport.cancel(recordingIDs: pausedRecordingIDs)

        for watch in watches where watch.ownerID != ownerID {
            watchTasks[watch.id]?.cancel()
            watchTasks[watch.id] = nil
        }
        persistWatches()
        if ownerID != nil {
            resumePendingWork()
        }
    }

    /// Records the deletion intent before touching files. A transient device
    /// storage failure therefore remains retryable across app launches and can
    /// never make the old recordings eligible for another account to claim.
    func removeLocalAccountData(ownerID: String) async {
        markLocalAccountDeletionPending(ownerID)
        _ = await cleanLocalAccountData(ownerID: ownerID)
    }

    func hasPendingLocalAccountDeletion(ownerID: String) -> Bool {
        pendingLocalAccountDeletionOwnerIDs.contains(ownerID)
    }

    private func retryPendingLocalAccountDeletions() async {
        for ownerID in pendingLocalAccountDeletionOwnerIDs {
            _ = await cleanLocalAccountData(ownerID: ownerID)
        }
    }

    private func cleanLocalAccountData(ownerID: String) async -> Bool {
        let recordingIDs = recorder.recordingIDsOwned(by: ownerID)
        if recorder.isRecording,
           recordingIDs.contains(where: { recorder.recording(withID: $0)?.state == .recording }) {
            _ = await recorder.stopFromSystem()
        }
        for recordingID in recordingIDs {
            uploadTasks[recordingID]?.cancel()
            uploadTasks[recordingID] = nil
            retryTasks[recordingID]?.cancel()
            retryTasks[recordingID] = nil
            retryAttempts[recordingID] = nil
        }
        await transport.cancel(recordingIDs: recordingIDs)
        let removedWatches = watches.filter {
            $0.ownerID == ownerID || $0.recordingID.map(recordingIDs.contains) == true
        }
        for watch in removedWatches {
            watchTasks[watch.id]?.cancel()
            watchTasks[watch.id] = nil
        }
        watches.removeAll {
            $0.ownerID == ownerID || $0.recordingID.map(recordingIDs.contains) == true
        }
        let watchesPersisted = persistWatches()
        recorder.setActiveOwnerID(nil)
        do {
            try recorder.deleteRecordingsOwned(by: ownerID)
            guard watchesPersisted else {
                statusMessage = "Device cleanup will retry automatically."
                return false
            }
            clearPendingLocalAccountDeletion(ownerID)
            return true
        } catch {
            statusMessage = "Device cleanup will retry automatically."
            return false
        }
    }

    private var pendingLocalAccountDeletionOwnerIDs: Set<String> {
        Set(
            localAccountDefaults.stringArray(
                forKey: Self.pendingLocalAccountDeletionOwnerIDsKey
            ) ?? []
        )
    }

    private func markLocalAccountDeletionPending(_ ownerID: String) {
        var ownerIDs = pendingLocalAccountDeletionOwnerIDs
        ownerIDs.insert(ownerID)
        localAccountDefaults.set(
            ownerIDs.sorted(),
            forKey: Self.pendingLocalAccountDeletionOwnerIDsKey
        )
    }

    private func clearPendingLocalAccountDeletion(_ ownerID: String) {
        var ownerIDs = pendingLocalAccountDeletionOwnerIDs
        ownerIDs.remove(ownerID)
        if ownerIDs.isEmpty {
            localAccountDefaults.removeObject(
                forKey: Self.pendingLocalAccountDeletionOwnerIDsKey
            )
        } else {
            localAccountDefaults.set(
                ownerIDs.sorted(),
                forKey: Self.pendingLocalAccountDeletionOwnerIDsKey
            )
        }
    }

    func resumePendingWork() {
        transport.receiver = self
        for recording in recorder.availableRecordings
        where recording.state == .serverProcessing {
            guard let remoteID = recording.remoteTranscriptionID,
                  !watches.contains(where: { $0.id == remoteID })
            else { continue }
            addWatch(
                TranscriptionWatch(
                    id: remoteID,
                    title: recording.displayTitle,
                    createdAt: recording.createdAt,
                    recordingID: recording.id,
                    ownerID: recording.ownerID
                )
            )
        }
        for watch in watches where watch.ownerID == recorder.activeOwnerID {
            startWatching(watch)
        }

        for recording in recorder.availableRecordings {
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
            for recording in self.recorder.availableRecordings
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
                if Self.isAuthenticationFailure(error) {
                    self.pauseForAuthentication(recordingID: recordingID, finalizing: true)
                } else if Self.isRetryable(error) {
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
        guard recorder.recording(withID: recordingID) != nil else { return }
        recorder.markServerAccepted(recordingID, transcriptionID: item.id)
        retryAttempts[recordingID] = nil
        retryTasks[recordingID]?.cancel()
        retryTasks[recordingID] = nil
        latestItem = item
        statusMessage = "Upload complete. Transcription is processing."
        let watch = TranscriptionWatch(
            id: item.id,
            title: item.displayTitle,
            createdAt: Date(),
            recordingID: recordingID,
            ownerID: recorder.recording(withID: recordingID)?.ownerID
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
                if let recordingID = watch.recordingID {
                    self.recorder.markServerCompleted(recordingID)
                }
                self.removeWatch(id: watch.id)
                self.statusMessage = "Transcription complete"
                return
            }
            var failures = 0
            while !Task.isCancelled {
                do {
                    let item = try await self.service.getAudioItem(watch.id)
                    failures = 0
                    self.clearAuthenticationPause(for: watch.id)
                    self.latestItem = item
                    if item.status == "completed" {
                        if let recordingID = watch.recordingID {
                            self.recorder.markServerCompleted(recordingID)
                        }
                        self.removeWatch(id: watch.id)
                        self.statusMessage = "Transcription complete"
                        NotificationService.notifyAudioComplete(
                            title: item.displayTitle,
                            itemId: item.id
                        )
                        return
                    }
                    if item.status == "failed" {
                        if let recordingID = watch.recordingID {
                            self.recorder.markServerFailed(
                                recordingID,
                                message: item.errorMessage ?? "Transcription failed. The recording is still on this iPhone.",
                                invalidSource: !item.isRetryable
                            )
                        }
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
                    switch Self.watchFailureDisposition(for: error) {
                    case .retry:
                        failures = min(failures + 1, 12)
                        // The persisted watch must remain live while the app does.
                        // A short outage should delay status delivery, not silently
                        // disable it until the next scene activation.
                        try? await Task.sleep(for: Self.watchRetryDelay(after: failures))
                    case .pauseForAuthentication:
                        let pausedWatch = self.recordAuthenticationPause(for: watch)
                        if Self.authenticationPauseHasExpired(pausedWatch) {
                            self.stopWatching(
                                pausedWatch,
                                message:
                                    "Sign-in recovery expired. Check Library for transcription status."
                            )
                        } else {
                            self.latestItem = nil
                            self.statusMessage =
                                "Sign in to continue checking transcription status."
                            // View appearances are not evidence of revocation.
                            // Preserve the watch throughout a bounded recovery
                            // window; a later signed-in poll still runs first.
                        }
                        return
                    case .stop:
                        self.stopWatching(
                            watch,
                            message:
                                "Transcription status could not be refreshed. Check Library for details."
                        )
                        return
                    }
                }
            }
        }
    }

    private func removeWatch(id: String) {
        watches.removeAll { $0.id == id }
        persistWatches()
    }

    private func recordAuthenticationPause(for watch: TranscriptionWatch) -> TranscriptionWatch {
        guard let index = watches.firstIndex(where: { $0.id == watch.id }) else {
            return Self.markingAuthenticationPaused(watch)
        }
        let updated = Self.markingAuthenticationPaused(watches[index])
        if updated != watches[index] {
            watches[index] = updated
            persistWatches()
        }
        return updated
    }

    private func clearAuthenticationPause(for id: String) {
        guard let index = watches.firstIndex(where: { $0.id == id }),
              watches[index].authenticationPausedAt != nil
        else { return }
        watches[index].authenticationPausedAt = nil
        persistWatches()
    }

    private func stopWatching(_ watch: TranscriptionWatch, message: String) {
        latestItem = nil
        if let recordingID = watch.recordingID {
            recorder.markServerFailed(recordingID, message: message, invalidSource: false)
        }
        removeWatch(id: watch.id)
        statusMessage = message
        NotificationService.notifyAudioStatusUnavailable(
            title: watch.title,
            itemId: watch.id
        )
    }

    @discardableResult
    private func persistWatches() -> Bool {
        do {
            try watchStore?.save(watches)
            return true
        } catch {
            statusMessage = "Completion alerts could not be saved. Check Library for status."
            return false
        }
    }

    private func handlePreparationFailure(_ error: Error, recordingID: UUID) {
        if Self.isAuthenticationFailure(error) {
            pauseForAuthentication(recordingID: recordingID, finalizing: false)
        } else if Self.isRetryable(error) {
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

    private func pauseForAuthentication(recordingID: UUID, finalizing: Bool) {
        retryTasks[recordingID]?.cancel()
        retryTasks[recordingID] = nil
        retryAttempts[recordingID] = nil

        let message: String
        if finalizing {
            message = "Upload is safe. Sign in to finish creating the transcription."
            recorder.markUploadFinalizing(recordingID, message: message)
        } else {
            message = "Recording is safe on this iPhone. Sign in to upload it."
            recorder.markWaitingForUpload(recordingID, message: message)
        }
        statusMessage = message
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

    static func isAuthenticationFailure(_ error: Error) -> Bool {
        if let apiError = error as? APIError {
            if case .authenticationRequired = apiError {
                return true
            }
            if case .httpError(let statusCode, _, _) = apiError, statusCode == 401 {
                return true
            }
        }
        return false
    }

    static func watchRetryDelay(after failureCount: Int) -> Duration {
        .seconds(min(max(failureCount, 1) * 5, 60))
    }

    static func watchFailureDisposition(for error: Error) -> TranscriptionWatchFailureDisposition {
        if let apiError = error as? APIError {
            if case .authenticationRequired = apiError {
                return .pauseForAuthentication
            }
            if case .httpError(let statusCode, _, _) = apiError, statusCode == 401 {
                return .pauseForAuthentication
            }
            return apiError.isRetryable ? .retry : .stop
        }
        return error is URLError ? .retry : .stop
    }

    static func authenticationPauseHasExpired(
        _ watch: TranscriptionWatch,
        now: Date = Date()
    ) -> Bool {
        guard let authenticationPausedAt = watch.authenticationPausedAt else { return false }
        return now.timeIntervalSince(authenticationPausedAt) >= maximumAuthenticationPauseAge
    }

    static func markingAuthenticationPaused(
        _ watch: TranscriptionWatch,
        now: Date = Date()
    ) -> TranscriptionWatch {
        guard watch.authenticationPausedAt == nil else { return watch }
        var updated = watch
        updated.authenticationPausedAt = now
        return updated
    }

    static func mimeType(for url: URL) -> String {
        if url.pathExtension.caseInsensitiveCompare("caf") == .orderedSame {
            // UniformTypeIdentifiers does not consistently publish a CAF MIME
            // mapping across supported iOS/macOS SDKs.
            return "audio/x-caf"
        }
        return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
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
