import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers

enum TranscriptionWatchFailureDisposition: Equatable {
    case retry
    case pauseForAuthentication
    case stop
}

@MainActor
protocol RecordingUploadServicing: AnyObject {
    func getAudioItem(
        _ id: String,
        expectedOwnerID: String?
    ) async throws -> AudioTranscription
    func uploadAudio(
        fileURL: URL,
        filename: String,
        mimeType: String,
        contentType: String,
        expectedOwnerID: String?
    ) async throws -> AudioTranscription
    func presignAudioUpload(
        filename: String,
        mimeType: String,
        sizeBytes: Int64,
        expectedOwnerID: String?
    ) async throws -> AudioUploadPresignResponse
    func completeAudioUpload(
        _ completion: AudioUploadCompleteRequest,
        expectedOwnerID: String?
    ) async throws -> AudioTranscription
    func importSharedLink(_ link: String, expectedOwnerID: String?) async throws
    func importSharedPDF(
        fileURL: URL,
        filename: String,
        expectedOwnerID: String?
    ) async throws
}

extension MediaToolsService: RecordingUploadServicing {}

/// Finishing a request after the app leaves the foreground needs a little time
/// from iOS. Without this, stopping from the lock screen or a Live Activity can
/// suspend the app before the presigned request hands off to the background
/// session. The recording stays safe either way; this only avoids waiting for
/// the next time the app opens.
@MainActor
private final class BackgroundTimeLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
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
    /// Lets the Library refresh after a shared PDF or link reaches the server.
    private(set) var sharedDocumentImports = 0

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
    private let service: any RecordingUploadServicing
    private let transport: BackgroundUploadService
    private let watchStore: TranscriptionWatchStore?
    private let localAccountDefaults: UserDefaults
    private let aiProcessingConsent: AIProcessingConsentManager
    private var watches: [TranscriptionWatch] = []
    private var uploadTasks: [UUID: Task<Void, Never>] = [:]
    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    private var watchTasks: [String: Task<Void, Never>] = [:]
    private var retryAttempts: [UUID: Int] = [:]
    private var hasReconciledTransfers = false
    private var attachedShareSessions: Set<String> = []
    /// Handles callbacks already queued by iOS while task descriptions change.
    private var verifiedOwnerAliases: [String: String] = [:]
    private let simulatesUpload: Bool
    private let isForeground: @MainActor () -> Bool
    private var sharedDocumentSends: [UUID: SharedDocumentSend] = [:]
    private var rejectedSharedDocuments: Set<UUID> = []
    private var reservationRecheck: Task<Void, Never>?

    /// `token` lets a cancelled send finish without clearing the send that
    /// replaced it after the same account signed back in.
    private struct SharedDocumentSend {
        let ownerID: String
        let token: UUID
        let task: Task<Void, Never>
    }

    init(
        recorder: RecordingCoordinator? = nil,
        service: any RecordingUploadServicing = MediaToolsService.shared,
        transport: BackgroundUploadService = .shared,
        watchStore: TranscriptionWatchStore? = nil,
        localAccountDefaults: UserDefaults = .standard,
        aiProcessingConsent: AIProcessingConsentManager? = nil,
        isForeground: @escaping @MainActor () -> Bool = {
            UIApplication.shared.applicationState == .active
        }
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
        self.aiProcessingConsent = aiProcessingConsent ?? .shared
        #if DEBUG
        simulatesUpload = ProcessInfo.processInfo.arguments.contains("-ui-test-simulated-upload")
        #else
        simulatesUpload = false
        #endif
        self.isForeground = isForeground
        watches = (try? self.watchStore?.load()) ?? []
        transport.receiver = self
        self.recorder.onSavedRecordingsChanged = { [weak self] in
            self?.autoQueueEligibleRecordings()
        }
        self.recorder.onRecordingsRestored = { [weak self] in
            guard let self else { return }
            self.hasReconciledTransfers = false
            self.resumePendingWork()
            self.processSharedItems()
        }
        self.aiProcessingConsent.onAutomaticTranscriptionStateChanged = { [weak self] in
            self?.automaticTranscriptionStateChanged()
        }
    }

    func queue(_ recording: LocalRecording) {
        guard recording.canUpload,
              let ownerID = recording.ownerID,
              ownerID == recorder.activeOwnerID,
              aiProcessingConsent.hasConsent(ownerID: ownerID)
        else { return }
        recorder.markWaitingForUpload(recording.id)
        retryAttempts[recording.id] = 0
        process(recordingID: recording.id)
    }

    /// Sends every finished recording that was saved with automatic transcription
    /// on. Safe to call repeatedly, because queueing moves a recording out of the
    /// eligible states. Without consent the audio simply stays on this iPhone.
    func autoQueueEligibleRecordings() {
        guard let ownerID = recorder.activeOwnerID,
              aiProcessingConsent.isAutoTranscribeEnabled(ownerID: ownerID),
              !hasPendingLocalAccountDeletion(ownerID: ownerID)
        else { return }
        let eligible = recorder.availableRecordings.filter(\.isWaitingForAutomaticTranscription)
        guard !eligible.isEmpty else { return }
        if aiProcessingConsent.hasAutomaticConsent(ownerID: ownerID) {
            eligible.forEach(queue)
        } else if isForeground(),
                  !recorder.isRecording,
                  aiProcessingConsent.activeOwnerID == ownerID {
            aiProcessingConsent.promptOnceForAutomaticTranscription()
        }
    }

    private func automaticTranscriptionStateChanged() {
        guard let ownerID = recorder.activeOwnerID else { return }
        if !aiProcessingConsent.hasConsent(ownerID: ownerID) {
            returnQueuedWorkAfterRevocation()
        }
        autoQueueEligibleRecordings()
        processSharedItems()
    }

    /// Without this, a revoke would strand queued recordings: they could be
    /// neither uploaded nor discarded while marked as in progress.
    private func returnQueuedWorkAfterRevocation() {
        cancelLinkSendsAfterRevocation()
        let queued = recorder.availableRecordings.filter {
            [.waitingForUpload, .uploading, .finalizingUpload].contains($0.state)
        }
        guard !queued.isEmpty else { return }
        let queuedIDs = Set(queued.map(\.id))
        // If permission returns, a tap sends this again. The extension must not also
        // finish its own copy in the meantime.
        for recording in queued { _ = recorder.takeOverShareUpload(recording) }
        for recordingID in queuedIDs {
            uploadTasks[recordingID]?.cancel()
            uploadTasks[recordingID] = nil
            retryTasks[recordingID]?.cancel()
            retryTasks[recordingID] = nil
            retryAttempts[recordingID] = nil
            recorder.markReadyAfterConsentRevoked(recordingID)
        }
        Task { [transport] in
            await transport.cancel(recordingIDs: queuedIDs)
        }
    }

    /// A link being sent can fall back to Whisper, so it stops with the rest.
    private func cancelLinkSendsAfterRevocation() {
        guard let ownerID = recorder.activeOwnerID else { return }
        for item in recorder.sharedDocuments(ownedBy: ownerID) where item.resolvedKind == .link {
            guard let send = sharedDocumentSends[item.id] else { continue }
            send.task.cancel()
            sharedDocumentSends[item.id] = nil
            recorder.markSharedDocumentManual(item.id)
        }
    }

    /// A queued recording may wait indefinitely for a connection. Automatic upload
    /// must not take away the choice to delete it during that wait. Nothing has
    /// reached the server yet, because an upload in flight is `.uploading`.
    func discard(_ recording: LocalRecording) {
        if recorder.recording(withID: recording.id)?.state == .waitingForUpload {
            uploadTasks[recording.id]?.cancel()
            uploadTasks[recording.id] = nil
            retryTasks[recording.id]?.cancel()
            retryTasks[recording.id] = nil
            retryAttempts[recording.id] = nil
            recorder.markReadyAfterConsentRevoked(recording.id)
        }
        guard let current = recorder.recording(withID: recording.id) else { return }
        recorder.discard(current)
    }

    /// Imports whatever the share extension staged, then sends PDFs and links to
    /// the server. Audio follows the same path as a finished recording.
    ///
    /// Each share belongs to the account that claimed it, so a failed share can
    /// never retry into whichever account is signed in later. A rejected share,
    /// such as a link with no video, would fail the same way on every foreground,
    /// so it waits for `retrySharedItem` from the Retry button.
    func processSharedItems() {
        recorder.importSharedItems()
        attachShareUploads()
        // The extension may hand a reserved share back with no later event from
        // iOS, so look once more rather than waiting for the next foreground.
        if recorder.hasShareReservations, reservationRecheck == nil {
            reservationRecheck = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard let self else { return }
                self.reservationRecheck = nil
                self.processSharedItems()
            }
        }
        guard let ownerID = recorder.activeOwnerID,
              !hasPendingLocalAccountDeletion(ownerID: ownerID)
        else { return }
        recorder.claimSharedDocuments()
        var hasLinkWaitingForConsent = false
        for item in recorder.sharedDocuments(ownedBy: ownerID)
        where !rejectedSharedDocuments.contains(item.id) {
            if item.resolvedKind == .link, !mayAutomaticallySendLink(item, ownerID: ownerID) {
                hasLinkWaitingForConsent = hasLinkWaitingForConsent
                    || item.autoTranscribeRequested == true
                continue
            }
            sendSharedDocument(item, ownerID: ownerID)
        }
        if hasLinkWaitingForConsent,
           aiProcessingConsent.isAutoTranscribeEnabled(ownerID: ownerID),
           isForeground(),
           !recorder.isRecording,
           aiProcessingConsent.activeOwnerID == ownerID {
            aiProcessingConsent.promptOnceForAutomaticTranscription()
        }
    }

    /// Shares the Library and Record tab should offer an action for: anything the
    /// recorder could not process, plus links held back for a deliberate tap.
    var sharesNeedingAttention: [ShareInboxStore.Item] {
        let unprocessed = Set(recorder.sharesNeedingAttention.map(\.id))
        return recorder.availableSharedItems.filter {
            unprocessed.contains($0.id) || isLinkWaitingForTap($0)
        }
    }

    func shareStatusMessage(for item: ShareInboxStore.Item) -> String {
        if let failure = recorder.pendingSharedErrors[item.id] { return failure }
        guard isLinkWaitingForTap(item), let ownerID = item.ownerID else { return "" }
        return aiProcessingConsent.hasConsent(ownerID: ownerID)
            ? "Saved on this iPhone. Tap Transcribe to send it."
            : "Saved on this iPhone. Allow AI processing to transcribe this link."
    }

    func shareActionTitle(for item: ShareInboxStore.Item) -> String {
        isLinkWaitingForTap(item) ? "Transcribe" : "Retry"
    }

    /// A deliberate tap, so a link may ask for permission and goes out even with
    /// "Automatically transcribe" off. It stays saved here if the person declines.
    func retrySharedItem(_ item: ShareInboxStore.Item) async {
        rejectedSharedDocuments.remove(item.id)
        processSharedItems()
        guard item.resolvedKind == .link,
              let ownerID = recorder.activeOwnerID,
              !hasPendingLocalAccountDeletion(ownerID: ownerID),
              sharedDocumentSends[item.id] == nil,
              await aiProcessingConsent.requestPermission(),
              recorder.activeOwnerID == ownerID,
              let current = recorder.sharedDocuments(ownedBy: ownerID)
                .first(where: { $0.id == item.id })
        else { return }
        sendSharedDocument(current, ownerID: ownerID)
    }

    /// Only for a deliberate tap. Stops any send first, so a removed share cannot
    /// still reach the server.
    func discardSharedItem(_ item: ShareInboxStore.Item) {
        sharedDocumentSends[item.id]?.task.cancel()
        sharedDocumentSends[item.id] = nil
        rejectedSharedDocuments.remove(item.id)
        recorder.discardSharedItem(item)
    }

    /// Links post to `/transcripts`, whose extractor falls back to Whisper when a
    /// video has no subtitles, so they need the same permission as a recording.
    private func mayAutomaticallySendLink(
        _ item: ShareInboxStore.Item,
        ownerID: String
    ) -> Bool {
        item.autoTranscribeRequested == true
            && aiProcessingConsent.isAutoTranscribeEnabled(ownerID: ownerID)
            && aiProcessingConsent.hasAutomaticConsent(ownerID: ownerID)
    }

    private func isLinkWaitingForTap(_ item: ShareInboxStore.Item) -> Bool {
        guard item.resolvedKind == .link,
              let ownerID = recorder.activeOwnerID,
              item.ownerID == ownerID,
              recorder.pendingSharedErrors[item.id] == nil,
              sharedDocumentSends[item.id] == nil
        else { return false }
        return !mayAutomaticallySendLink(item, ownerID: ownerID)
    }

    private func sendSharedDocument(_ item: ShareInboxStore.Item, ownerID: String) {
        guard sharedDocumentSends[item.id] == nil, item.ownerID == ownerID else { return }
        let lease = BackgroundTimeLease(name: "share-\(item.id.uuidString)")
        let token = UUID()
        let task = Task { [weak self] in
            defer { lease.end() }
            guard let self else { return }
            defer {
                if self.sharedDocumentSends[item.id]?.token == token {
                    self.sharedDocumentSends[item.id] = nil
                }
            }
            guard self.recorder.activeOwnerID == ownerID, !Task.isCancelled else { return }
            do {
                switch item.resolvedKind {
                case .link:
                    guard self.aiProcessingConsent.hasConsent(ownerID: ownerID) else { return }
                    try await self.service.importSharedLink(
                        item.link ?? "",
                        expectedOwnerID: ownerID
                    )
                case .pdf:
                    // No consent check: /pdf/extract reads the text layer on our
                    // own server and calls no AI provider. Summaries and chat over
                    // the result ask for permission when they are requested.
                    guard let fileURL = self.recorder.sharedFileURL(for: item) else { return }
                    try await self.service.importSharedPDF(
                        fileURL: fileURL,
                        filename: item.originalName,
                        expectedOwnerID: ownerID
                    )
                case .audio:
                    return
                }
                // The server has it under this owner, so keeping a copy would only
                // create a duplicate when that account signs back in.
                self.recorder.completeSharedDocument(item)
                if self.recorder.activeOwnerID == ownerID {
                    self.sharedDocumentImports += 1
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.recorder.activeOwnerID == ownerID, !Task.isCancelled else { return }
                if !Self.isRetryable(error) {
                    self.rejectedSharedDocuments.insert(item.id)
                }
                // The staged copy stays in the inbox, so foregrounding or
                // Retry can send it again and nothing is lost.
                self.recorder.failSharedDocument(
                    item,
                    message: error.localizedDescription
                )
            }
        }
        sharedDocumentSends[item.id] = SharedDocumentSend(ownerID: ownerID, token: token, task: task)
    }

    private func cancelSharedDocumentSends(where shouldCancel: (String) -> Bool) {
        for (id, send) in sharedDocumentSends where shouldCancel(send.ownerID) {
            send.task.cancel()
            sharedDocumentSends[id] = nil
        }
    }

    /// A share upload goes straight to storage with its own presigned URL and
    /// never carries the bearer token, so another account becoming active cannot
    /// misuse it. Cancelling it would only force a new presign and a full re-upload
    /// when its owner returns. A late completion is recorded without a credential,
    /// and account deletion still cancels it by owner.
    nonisolated static func transfersToCancelOnOwnerChange(
        paused: Set<UUID>,
        shareUploadRecordingIDs: Set<UUID>
    ) -> Set<UUID> {
        paused.subtracting(shareUploadRecordingIDs)
    }

    /// Keeps upload/finalization credentials aligned with the signed-in account.
    /// Work owned by another account is paused instead of ever being finalized
    /// with the new account's bearer token.
    func setActiveOwnerID(_ ownerID: String?) async {
        cancelSharedDocumentSends { $0 != ownerID }
        await retryPendingLocalAccountDeletions()
        recorder.setActiveOwnerID(ownerID)
        attachShareUploads()
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
        await transport.cancel(recordingIDs: Self.transfersToCancelOnOwnerChange(
            paused: pausedRecordingIDs,
            shareUploadRecordingIDs: Set(pausedRecordingIDs.filter {
                recorder.recording(withID: $0)?.shareUploadSessionIdentifier != nil
            })
        ))
        hasReconciledTransfers = false

        for watch in watches where watch.ownerID != ownerID {
            watchTasks[watch.id]?.cancel()
            watchTasks[watch.id] = nil
        }
        persistWatches()
        if ownerID != nil {
            resumePendingWork()
            // Shares staged while signed out have been waiting for this moment.
            processSharedItems()
        }
    }

    /// Called only with a provider subject and the users.id the server verified
    /// for that same account. This is safe to repeat after a crash.
    func migrateOwnerID(from clerkID: String, to userID: String) async throws {
        guard clerkID != userID else { return }
        verifiedOwnerAliases[clerkID] = userID
        cancelSharedDocumentSends { $0 == clerkID }
        let migratingIDs = recorder.recordingIDsOwned(by: clerkID)
        for recordingID in migratingIDs {
            uploadTasks[recordingID]?.cancel()
            uploadTasks[recordingID] = nil
            retryTasks[recordingID]?.cancel()
            retryTasks[recordingID] = nil
        }
        try recorder.migrateOwnerID(from: clerkID, to: userID)

        var migratedWatches = watches
        for index in migratedWatches.indices where migratedWatches[index].ownerID == clerkID {
            migratedWatches[index].ownerID = userID
        }
        try watchStore?.save(migratedWatches)
        for watch in watches where watch.ownerID == clerkID {
            watchTasks[watch.id]?.cancel()
            watchTasks[watch.id] = nil
        }
        watches = migratedWatches

        var pendingDeletionOwners = pendingLocalAccountDeletionOwnerIDs
        if pendingDeletionOwners.remove(clerkID) != nil {
            pendingDeletionOwners.insert(userID)
            localAccountDefaults.set(
                pendingDeletionOwners.sorted(),
                forKey: Self.pendingLocalAccountDeletionOwnerIDsKey
            )
        }
        await transport.migrateOwnerID(from: clerkID, to: userID)
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
        await transport.cancelUploads(ownedBy: ownerID)
        cancelSharedDocumentSends { $0 == ownerID }
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
        if recorder.activeOwnerID == ownerID {
            recorder.setActiveOwnerID(nil)
        }
        do {
            try recorder.deleteRecordingsOwned(by: ownerID)
            aiProcessingConsent.removeConsent(ownerID: ownerID)
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
        attachShareUploads()
        reconcileQueuedWorkWithConsent()
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
        autoQueueEligibleRecordings()

        guard !hasReconciledTransfers else { return }
        hasReconciledTransfers = true
        let reconciledOwnerID = recorder.activeOwnerID
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            let activeIDs = await self.transport.activeRecordingIDs()
            guard self.recorder.activeOwnerID == reconciledOwnerID else { return }
            // A finished share has no task left. Its inbox entry is what says so.
            self.recorder.importSharedItems()
            for recording in self.recorder.availableRecordings
            where recording.state == .finalizingUpload {
                self.finalize(recordingID: recording.id)
            }
            for recording in self.recorder.availableRecordings
            where recording.state == .uploading && !activeIDs.contains(recording.id) {
                guard self.isActiveOwner(
                    recordingID: recording.id,
                    expectedOwnerID: reconciledOwnerID
                ) else { continue }
                switch self.recorder.takeOverShareUpload(recording) {
                case .finishedByExtension:
                    self.recorder.markUploadFinalizing(recording.id)
                    self.finalize(recordingID: recording.id)
                case .undetermined:
                    // Nothing is sent until this is settled. The next foreground asks again.
                    self.hasReconciledTransfers = false
                case .takenOver:
                    self.recorder.markWaitingForUpload(
                        recording.id,
                        message: "The interrupted upload will resume automatically."
                    )
                    self.process(recordingID: recording.id)
                }
            }
        }
    }

    /// Revoking saves the new permission before it returns queued recordings. If
    /// the app ends between those steps, or the state cannot be saved, a recording
    /// would stay marked as in progress: unable to upload, finish, or be discarded.
    private func reconcileQueuedWorkWithConsent() {
        guard let ownerID = recorder.activeOwnerID,
              !aiProcessingConsent.hasConsent(ownerID: ownerID)
        else { return }
        // Recordings move to a verified owner ID just before consent does. That
        // gap is not a revocation, and an event can arrive during it.
        let consentIsStillMigrating = verifiedOwnerAliases.contains {
            $0.value == ownerID && aiProcessingConsent.hasConsent(ownerID: $0.key)
        }
        guard !consentIsStillMigrating else { return }
        returnQueuedWorkAfterRevocation()
    }

    /// An attached session reports the moment the app connects to it, so its
    /// recording must exist first. Reconciliation then treats it like any other.
    private func attachShareUploads() {
        let identifiers = recorder.shareUploadSessionIdentifiers
        guard !identifiers.isSubset(of: attachedShareSessions) else { return }
        attachedShareSessions.formUnion(identifiers)
        hasReconciledTransfers = false
        transport.attachShareSessions(identifiers)
    }

    func receiveBackgroundUploadEvent(_ event: BackgroundUploadEvent) {
        let metadata: BackgroundUploadMetadata
        switch event {
        case .progress(let value, _), .completed(let value), .failed(let value, _, _):
            metadata = value
        }
        // The extension's upload can finish before this app has seen the share.
        if recorder.recording(withID: metadata.recordingID) == nil {
            recorder.importSharedItems()
        }
        defer {
            if case .progress = event {} else {
                recorder.releaseShareSource(recordingID: metadata.recordingID)
            }
        }
        // A retry presigns a new object. A task still reporting on the old one has
        // nothing to say about this recording, and completing with it would create
        // a second transcription.
        if let recording = recorder.recording(withID: metadata.recordingID),
           recording.uploadObjectKey != metadata.objectKey {
            return
        }
        guard let rawOwnerID = metadata.ownerID
                ?? recorder.recording(withID: metadata.recordingID)?.ownerID
        else { return }
        let resolvedOwnerID = verifiedOwnerAliases[rawOwnerID] ?? rawOwnerID
        guard isActiveOwner(recordingID: metadata.recordingID, expectedOwnerID: resolvedOwnerID) else {
            // An upload this app started is cancelled when its account signs out,
            // and a late result is ignored. The extension's upload was never this
            // app's to cancel, so its bytes can arrive with that account signed out.
            // Remembering that uses no credential, and spares a second upload.
            if case .completed = event,
               let recording = recorder.recording(withID: metadata.recordingID),
               recording.ownerID == resolvedOwnerID,
               recording.shareUploadSessionIdentifier != nil {
                recorder.markUploadFinalizing(metadata.recordingID)
            }
            return
        }

        // A background launch can deliver this before any scene resumes work.
        reconcileQueuedWorkWithConsent()

        switch event {
        case .progress(let metadata, let fractionCompleted):
            recorder.updateUploadProgress(metadata.recordingID, progress: fractionCompleted)
        case .completed(let metadata):
            retryTasks[metadata.recordingID]?.cancel()
            retryTasks[metadata.recordingID] = nil
            recorder.markUploadFinalizing(metadata.recordingID)
            finalize(recordingID: metadata.recordingID)
        case .failed(let metadata, let message, let shouldRetry):
            // Cancelling a revoked upload reports back here. The recording has
            // already returned to the saved state, and must stay there.
            guard recorder.recording(withID: metadata.recordingID)?.state != .ready else { return }
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
              let ownerID = recording.ownerID,
              aiProcessingConsent.hasConsent(ownerID: ownerID),
              isActiveOwner(recordingID: recordingID, expectedOwnerID: ownerID),
              recording.state == .waitingForUpload || recording.state == .uploadFailed,
              let fileURL = recorder.fileURL(for: recording)
        else { return }

        let lease = BackgroundTimeLease(name: "upload-\(recordingID.uuidString)")
        uploadTasks[recordingID] = Task { [weak self] in
            defer { lease.end() }
            guard let self else { return }
            defer { self.uploadTasks[recordingID] = nil }
            guard self.isActiveOwner(
                recordingID: recordingID,
                expectedOwnerID: ownerID
            ), self.aiProcessingConsent.hasConsent(ownerID: ownerID),
               !Task.isCancelled else { return }
            if self.simulatesUpload {
                await self.simulateUpload(recording: recording, ownerID: ownerID)
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
                    sizeBytes: size.int64Value,
                    expectedOwnerID: ownerID
                )
                guard self.isActiveOwner(
                    recordingID: recordingID,
                    expectedOwnerID: ownerID
                ), self.aiProcessingConsent.hasConsent(ownerID: ownerID),
                   !Task.isCancelled else { return }
                let metadata = BackgroundUploadMetadata(
                    recordingID: recording.id,
                    ownerID: ownerID,
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
                guard self.isActiveOwner(
                    recordingID: recordingID,
                    expectedOwnerID: ownerID
                ), !Task.isCancelled else { return }
                await self.performForegroundFallback(
                    recordingID: recordingID,
                    fileURL: fileURL,
                    ownerID: ownerID
                )
            } catch {
                guard self.isActiveOwner(
                    recordingID: recordingID,
                    expectedOwnerID: ownerID
                ), !Task.isCancelled else { return }
                self.handlePreparationFailure(error, recordingID: recordingID)
            }
        }
    }

    private func performForegroundFallback(
        recordingID: UUID,
        fileURL: URL,
        ownerID: String
    ) async {
        guard let recording = recorder.recording(withID: recordingID),
              isActiveOwner(recordingID: recordingID, expectedOwnerID: ownerID),
              aiProcessingConsent.hasConsent(ownerID: ownerID)
        else { return }
        do {
            let item = try await service.uploadAudio(
                fileURL: fileURL,
                filename: recording.uploadFilename,
                mimeType: Self.mimeType(for: fileURL),
                contentType: recording.contentType,
                expectedOwnerID: ownerID
            )
            guard isActiveOwner(recordingID: recordingID, expectedOwnerID: ownerID),
                  !Task.isCancelled
            else { return }
            accept(item: item, recordingID: recordingID, ownerID: ownerID)
        } catch {
            guard isActiveOwner(recordingID: recordingID, expectedOwnerID: ownerID),
                  !Task.isCancelled
            else { return }
            handlePreparationFailure(error, recordingID: recordingID)
        }
    }

    private func finalize(recordingID: UUID) {
        guard uploadTasks[recordingID] == nil,
              let recording = recorder.recording(withID: recordingID),
              let ownerID = recording.ownerID,
              aiProcessingConsent.hasConsent(ownerID: ownerID),
              isActiveOwner(recordingID: recordingID, expectedOwnerID: ownerID),
              recording.state == .finalizingUpload,
              let objectKey = recording.uploadObjectKey,
              let sizeBytes = recording.uploadSizeBytes
        else { return }

        let lease = BackgroundTimeLease(name: "finalize-\(recordingID.uuidString)")
        uploadTasks[recordingID] = Task { [weak self] in
            defer { lease.end() }
            guard let self else { return }
            defer { self.uploadTasks[recordingID] = nil }
            guard self.isActiveOwner(
                recordingID: recordingID,
                expectedOwnerID: ownerID
            ), self.aiProcessingConsent.hasConsent(ownerID: ownerID),
               !Task.isCancelled else { return }
            do {
                let item = try await self.service.completeAudioUpload(
                    AudioUploadCompleteRequest(
                        objectKey: objectKey,
                        originalName: recording.uploadFilename,
                        sizeBytes: sizeBytes,
                        contentType: recording.contentType
                    ),
                    expectedOwnerID: ownerID
                )
                guard self.isActiveOwner(
                    recordingID: recordingID,
                    expectedOwnerID: ownerID
                ), !Task.isCancelled else { return }
                self.accept(item: item, recordingID: recordingID, ownerID: ownerID)
            } catch {
                guard self.isActiveOwner(
                    recordingID: recordingID,
                    expectedOwnerID: ownerID
                ), !Task.isCancelled else { return }
                if Self.isAuthenticationFailure(error) {
                    self.pauseForAuthentication(recordingID: recordingID, finalizing: true)
                } else if Self.isRetryable(error) {
                    self.statusMessage = "Upload is safe. Finishing will retry automatically."
                    self.scheduleRetry(recordingID: recordingID, finalizing: true, after: error)
                } else {
                    self.recorder.markUploadFailed(recordingID, message: error.localizedDescription)
                    self.statusMessage = error.localizedDescription
                }
            }
        }
    }

    private func accept(item: AudioTranscription, recordingID: UUID, ownerID: String) {
        guard isActiveOwner(recordingID: recordingID, expectedOwnerID: ownerID) else { return }
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
        guard watchTasks[watch.id] == nil,
              let ownerID = watch.ownerID,
              recorder.activeOwnerID == ownerID
        else { return }
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
                NotificationService.notifyAudioComplete(title: item.displayTitle, itemId: item.id)
                return
            }
            var failures = 0
            while !Task.isCancelled {
                do {
                    guard self.recorder.activeOwnerID == ownerID,
                          !Task.isCancelled
                    else { return }
                    let item = try await self.service.getAudioItem(
                        watch.id,
                        expectedOwnerID: ownerID
                    )
                    guard self.recorder.activeOwnerID == ownerID,
                          !Task.isCancelled
                    else { return }
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
                    guard self.recorder.activeOwnerID == ownerID,
                          !Task.isCancelled
                    else { return }
                    switch Self.watchFailureDisposition(for: error) {
                    case .retry:
                        failures = min(failures + 1, 12)
                        // The persisted watch must remain live while the app does.
                        // A short outage should delay status delivery, not silently
                        // disable it until the next scene activation.
                        try? await Task.sleep(for: Self.watchRetryDelay(
                            after: failures,
                            serverWait: Self.serverRequestedWait(error)
                        ))
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
            scheduleRetry(recordingID: recordingID, after: error)
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

    /// `error` is what made this retry necessary. A 429 says how long the server
    /// wants to be left alone, and retrying before then only earns another 429.
    private func scheduleRetry(recordingID: UUID, finalizing: Bool = false, after error: Error? = nil) {
        guard retryTasks[recordingID] == nil else { return }
        let attempt = (retryAttempts[recordingID] ?? 0) + 1
        retryAttempts[recordingID] = attempt
        let delay = Self.retryDelay(attempt: attempt, serverWait: error.flatMap(Self.serverRequestedWait))
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

    static func watchRetryDelay(after failureCount: Int, serverWait: TimeInterval? = nil) -> Duration {
        .seconds(max(Double(min(max(failureCount, 1) * 5, 60)), cappedServerWait(serverWait)))
    }

    /// Never sooner than the backoff, and never sooner than the server asked.
    static func retryDelay(attempt: Int, serverWait: TimeInterval? = nil) -> TimeInterval {
        max(min(pow(2, Double(max(attempt, 1) - 1)) * 2, 60), cappedServerWait(serverWait))
    }

    static func serverRequestedWait(_ error: Error) -> TimeInterval? {
        if case APIError.rateLimited(let retryAfter, _) = error { return retryAfter }
        return nil
    }

    /// A bad header must not park a recording for hours.
    private static func cappedServerWait(_ wait: TimeInterval?) -> TimeInterval {
        guard let wait, wait.isFinite, wait > 0 else { return 0 }
        return min(wait, 15 * 60)
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
        ShareDirectUpload.mimeType(for: url)
    }

    private func simulateUpload(recording: LocalRecording, ownerID: String) async {
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
        #if DEBUG
        UITestAPIProtocol.acceptAudio(title: recording.displayTitle)
        #endif
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
        accept(item: item, recordingID: recording.id, ownerID: ownerID)
    }

    private func isActiveOwner(recordingID: UUID, expectedOwnerID: String?) -> Bool {
        guard let expectedOwnerID,
              recorder.activeOwnerID == expectedOwnerID,
              recorder.recording(withID: recordingID)?.ownerID == expectedOwnerID
        else { return false }
        return true
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
