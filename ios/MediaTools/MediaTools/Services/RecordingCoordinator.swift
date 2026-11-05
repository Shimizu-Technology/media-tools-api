import AVFoundation
import Foundation
import Observation
import SwiftUI
import UIKit

enum RecordingCaptureState: Equatable {
    case idle
    case recording
    case paused
    case interrupted
}

/// Owns microphone capture for the whole app rather than for one SwiftUI view.
/// This is what allows an active recording to survive tab changes, screen lock,
/// and ordinary backgrounding. System controls and App Intents call this same
/// coordinator so every entry point shares one recording lifecycle.
enum ShareUploadTakeover: Equatable {
    case takenOver
    case finishedByExtension
    case undetermined
}

@MainActor
@Observable
final class RecordingCoordinator {
    static let shared = RecordingCoordinator()
    static let pendingLegacyRecordingOwnerIDKey = "pendingLegacyRecordingOwnerID"
    static let pendingShareClaimOwnerIDKey = "pendingShareClaimOwnerID"

    private(set) var captureState: RecordingCaptureState = .idle
    private(set) var isStarting = false
    private(set) var pendingRecordings: [LocalRecording] = []
    private(set) var pendingSharedItems: [ShareInboxStore.Item] = []
    private(set) var pendingSharedErrors: [UUID: String] = [:]
    private(set) var activeOwnerID: String?
    private(set) var duration: TimeInterval = 0
    private(set) var audioLevel: CGFloat = 0
    /// The microphone's recent levels, for the bars on the recording screen.
    private(set) var levelMeter = LiveLevelMeter()
    private(set) var statusMessage: String?
    private(set) var storageIsLow = false
    var errorMessage: String?
    var permissionDenied = false

    private var audioRecorder: AVAudioRecorder?
    private var activeRecordingID: UUID?
    private var timer: Timer?
    private var activityUpdateTask: Task<Void, Never>?
    private var lastCheckpointedDuration: TimeInterval = 0
    private var lastStorageCheckDuration: TimeInterval = 0
    private var stateBeforeInterruption: RecordingCaptureState?
    private let notificationObservers = NotificationObserverBag()
    private var store: RecordingStore?
    /// False until the saved manifest has been read. Until then this launch only
    /// knows part of the list, so it must not replace the manifest. See
    /// `persistPendingRecordings`.
    private var hasRestoredManifest = false
    private var hasAttemptedRestoration = false
    private var unmergedRecordingIDs: Set<UUID> = []
    private var shareInbox: ShareInboxStore?
    private let simulatesCapture: Bool
    private let activityManager: RecordingActivityManaging
    private let availableCapacity: (URL) -> Int64?
    private let localAccountDefaults: UserDefaults
    /// Called whenever a finished recording appears, so automatic transcription
    /// has one entry point for every capture path: Action Button, Live Activity,
    /// the in-app button, and imported shares.
    var onSavedRecordingsChanged: (() -> Void)?
    /// Called when recordings appear after a restore that first failed, because
    /// the upload coordinator has not seen any of their queued work.
    var onRecordingsRestored: (() -> Void)?

    static let minimumStartCapacityBytes: Int64 = 100 * 1_024 * 1_024
    static let criticalRecordingCapacityBytes: Int64 = 50 * 1_024 * 1_024

    /// `isRecording` means a recording session is still active, including a
    /// deliberate pause or a temporary system interruption. This keeps stop,
    /// recovery, and the Action Button safe in every non-idle state.
    var isRecording: Bool { captureState != .idle }
    var isPaused: Bool { captureState == .paused }
    var isInterrupted: Bool { captureState == .interrupted }

    init(
        store: RecordingStore? = nil,
        simulatesCapture: Bool? = nil,
        activityManager: RecordingActivityManaging? = nil,
        localAccountDefaults: UserDefaults = .standard,
        availableCapacity: @escaping (URL) -> Int64? = RecordingStorageCapacity.available,
        shareInbox: ShareInboxStore? = nil
    ) {
        #if DEBUG
        self.simulatesCapture = simulatesCapture
            ?? ProcessInfo.processInfo.arguments.contains("-ui-test-simulated-recording")
        #else
        self.simulatesCapture = false
        #endif
        self.activityManager = activityManager ?? RecordingActivityManager.shared
        self.availableCapacity = availableCapacity
        self.localAccountDefaults = localAccountDefaults
        self.shareInbox = shareInbox

        if let store {
            self.store = store
        } else {
            do {
                self.store = try RecordingStore()
            } catch {
                self.store = nil
                errorMessage = Self.storageUnavailableMessage
            }
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ui-test-reset-recordings") {
            try? self.store?.deleteAllRecordings()
        }
        if ProcessInfo.processInfo.arguments.contains("-ui-test-needs-you") {
            seedNeedsYouFixtures()
        }
        #endif
        restorePendingRecordings()
        observeAudioSession()
        observeProtectedData()
    }

    var formattedDuration: String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// The active capture is persisted immediately for crash recovery, but it
    /// should not appear as a second actionable item while recording.
    var availableRecordings: [LocalRecording] {
        pendingRecordings.filter {
            $0.state != .recording && $0.ownerID == activeOwnerID
        }
    }

    /// Changes only when an upload changes state, not on every progress tick, so
    /// observers can refresh a server list without turning it into polling.
    var uploadStateSignature: String {
        availableRecordings.map { "\($0.id.uuidString):\($0.state.rawValue)" }.joined(separator: "|")
    }

    private var autoTranscribeEnabledForNewRecordings: Bool {
        AutoTranscribePreference(defaults: localAccountDefaults).isEnabled(ownerID: activeOwnerID)
    }

    /// Switches the visible device workspace. Unowned recordings are legacy or
    /// signed-out Quick Captures, so the first signed-in account claims them.
    func setActiveOwnerID(_ ownerID: String?) {
        activeOwnerID = ownerID
        guard ownerID != nil else { return }
        retryRestorationIfNeeded()
        claimUnownedRecordings()
    }

    /// The intended owner is saved separately before rewriting the manifest; if
    /// that rewrite fails, a later account can never claim the same files. An
    /// unread manifest may hold unowned recordings, so this account's place in
    /// line is saved until it has been read.
    private func claimUnownedRecordings() {
        guard let ownerID = activeOwnerID else { return }
        let pendingClaimOwnerID = localAccountDefaults.string(
            forKey: Self.pendingLegacyRecordingOwnerIDKey
        )
        let hasUnownedRecordings = pendingRecordings.contains { $0.ownerID == nil }
        guard pendingClaimOwnerID != nil || hasUnownedRecordings || !hasRestoredManifest else {
            return
        }
        let claimOwnerID = pendingClaimOwnerID ?? ownerID
        localAccountDefaults.set(
            claimOwnerID,
            forKey: Self.pendingLegacyRecordingOwnerIDKey
        )
        for index in pendingRecordings.indices where pendingRecordings[index].ownerID == nil {
            pendingRecordings[index].ownerID = claimOwnerID
        }
        do {
            try persistPendingRecordings()
            if hasRestoredManifest {
                localAccountDefaults.removeObject(forKey: Self.pendingLegacyRecordingOwnerIDKey)
            }
        } catch {
            errorMessage = "Device recordings are protected, but their account assignment will retry."
        }
    }

    /// The server verified that a provider subject resolves to this users.id.
    /// Rewrite only that exact subject; another account's recordings stay put.
    func migrateOwnerID(from clerkID: String, to userID: String) throws {
        guard clerkID != userID else { return }
        // The manifest may hold this account's recordings. Migrating only what is
        // in memory would strand those under an owner ID that never signs in again.
        retryRestorationIfNeeded()
        guard hasRestoredManifest else { throw RecordingCoordinatorError.manifestUnavailable }
        try migrateSharedDocuments(from: clerkID, to: userID)
        let previous = pendingRecordings
        for index in pendingRecordings.indices where pendingRecordings[index].ownerID == clerkID {
            pendingRecordings[index].ownerID = userID
        }
        do {
            try persistPendingRecordings()
            if localAccountDefaults.string(forKey: Self.pendingLegacyRecordingOwnerIDKey) == clerkID {
                localAccountDefaults.set(userID, forKey: Self.pendingLegacyRecordingOwnerIDKey)
            }
        } catch {
            pendingRecordings = previous
            throw error
        }
    }

    func recordingIDsOwned(by ownerID: String) -> Set<UUID> {
        Set(pendingRecordings.lazy.filter { $0.ownerID == ownerID }.map(\.id))
    }

    func deleteRecordingsOwned(by ownerID: String) throws {
        guard let store else { throw RecordingCoordinatorError.storageUnavailable }
        let owned = pendingRecordings.filter { $0.ownerID == ownerID }
        for recording in owned {
            try store.deleteFile(for: recording)
        }
        pendingRecordings.removeAll { $0.ownerID == ownerID }
        try persistPendingRecordings()
        try deleteSharedDocuments(ownedBy: ownerID)
        // Recordings still in the unread manifest belong to this account too. The
        // caller keeps its deletion intent and retries after this throws.
        guard hasRestoredManifest else { throw RecordingCoordinatorError.manifestUnavailable }
        if pendingRecordings.contains(where: { $0.ownerID == ownerID }) {
            try deleteRecordingsOwned(by: ownerID)
        }
    }

    func fileURL(for recording: LocalRecording) -> URL? {
        store?.fileURL(for: recording)
    }

    /// Provider IDs still owning work on this device. Server IDs are UUIDs, so
    /// these can only be left over from before first-party sign-in.
    var legacyProviderOwnerIDs: Set<String> {
        let owners = pendingRecordings.map(\.ownerID) + pendingSharedItems.map(\.ownerID)
        return Set(owners.compactMap { owner in
            owner?.hasPrefix("user_") == true ? owner : nil
        })
    }

    func recording(withID id: UUID) -> LocalRecording? {
        pendingRecordings.first { $0.id == id }
    }

    /// Move completed share-sheet handoffs into the same durable recording
    /// queue used by Files and Quick Record. Never upload here: the upload
    /// coordinator checks account ownership and AI processing consent. PDFs and
    /// links have no recording, so they stay in the inbox until it sends them.
    ///
    /// The share's ID becomes the recording's ID, which is what keeps a share the
    /// extension is already uploading from being uploaded again. Its source stays
    /// in the inbox until that transfer ends, because iOS may still be reading it.
    func importSharedItems() {
        retryRestorationIfNeeded()
        do {
            let inbox = try resolvedShareInbox()
            var errors = pendingSharedErrors
            for item in try inbox.pendingItems() where item.resolvedKind == .audio {
                // The extension is still presigning. It either starts the upload
                // or releases this share within a few seconds.
                if item.directUpload?.isReservationActive() == true { continue }
                do {
                    var recording = try importShare(item, from: inbox)
                    // The extension learned the bytes arrived after this share was
                    // imported. They must not be sent a second time.
                    if item.directUpload?.uploadFinished == true, recording.state == .uploading {
                        markUploadFinalizing(item.id)
                        recording = self.recording(withID: item.id) ?? recording
                    }
                    if recording.state == .uploading,
                       recording.shareUploadSessionIdentifier == item.directUpload?.sessionIdentifier,
                       recording.shareUploadSessionIdentifier != nil {
                        continue
                    }
                    try inbox.remove(item)
                    errors[item.id] = nil
                } catch {
                    errors[item.id] = error.localizedDescription
                }
            }
            pendingSharedItems = try inbox.pendingItems().filter { item in
                item.directUpload?.isReservationActive() != true && recording(withID: item.id) == nil
            }
            pendingSharedErrors = errors
            onSavedRecordingsChanged?()
        } catch {
            errorMessage = "Shared files are unavailable. Restart Media Tools to try again."
        }
    }

    private func importShare(
        _ item: ShareInboxStore.Item,
        from inbox: ShareInboxStore
    ) throws -> LocalRecording {
        // A direct upload belongs to the account whose key started it, whoever is
        // signed in by now. Any other share is claimed the usual way.
        let ownerID = item.ownerID ?? activeOwnerID
        let autoTranscribe = AutoTranscribePreference(defaults: localAccountDefaults)
            .isEnabled(ownerID: ownerID)
        // If the setting went off after the share started, the transfer is ignored
        // when it ends, and the recording waits here for a deliberate tap.
        let directUpload = autoTranscribe && item.directUpload?.isStarted == true
            ? item.directUpload
            : nil
        return try importRecording(
            from: inbox.fileURL(for: item),
            contentType: ShareDirectUpload.contentType,
            shareID: item.id,
            originalName: item.originalName,
            autoTranscribe: autoTranscribe,
            ownerID: ownerID,
            directUpload: directUpload
        )
    }

    /// True while the extension may still release a share, so the coordinator
    /// knows to look once more instead of waiting for the next foreground.
    var hasShareReservations: Bool {
        guard let inbox = try? resolvedShareInbox(),
              let items = try? inbox.pendingItems() else { return false }
        return items.contains { $0.directUpload?.isReservationActive() == true }
    }

    /// Every extension upload that may still report back, for any account. A
    /// session must be attached before its tasks can be seen or cancelled.
    var shareUploadSessionIdentifiers: Set<String> {
        Set(pendingRecordings.lazy.filter { $0.state == .uploading }
            .compactMap(\.shareUploadSessionIdentifier))
    }

    /// A share's task has gone quiet, which can also mean the extension's PUT just
    /// finished and it has not yet said so. This settles it with the extension before
    /// anything is sent again. Any other recording has no one to settle with.
    func takeOverShareUpload(_ recording: LocalRecording) -> ShareUploadTakeover {
        guard recording.shareUploadSessionIdentifier != nil else { return .takenOver }
        guard let inbox = try? resolvedShareInbox() else { return .undetermined }
        switch inbox.claimTransfer(.appTookOver, shareID: recording.id) {
        case .held(.appTookOver), .shareGone:
            return .takenOver
        case .held(.extensionFinished):
            return .finishedByExtension
        case .undetermined:
            return .undetermined
        }
    }

    /// The transfer has ended, so its source no longer needs to stay in the inbox.
    /// The recording store holds its own copy.
    func releaseShareSource(recordingID: UUID) {
        guard let recording = recording(withID: recordingID), recording.state != .uploading,
              let inbox = try? resolvedShareInbox() else { return }
        try? inbox.removeItem(id: recordingID)
    }

    private func resolvedShareInbox() throws -> ShareInboxStore {
        if let shareInbox { return shareInbox }
        let inbox = try ShareInboxStore()
        shareInbox = inbox
        return inbox
    }

    func sharedFileURL(for item: ShareInboxStore.Item) -> URL? {
        guard item.resolvedKind != .link,
              pendingSharedItems.contains(where: { $0.id == item.id })
        else { return nil }
        return shareInbox?.fileURL(for: item)
    }

    /// A share claimed by another account is hidden, like that account's recordings.
    var availableSharedItems: [ShareInboxStore.Item] {
        pendingSharedItems.filter { $0.ownerID == nil || $0.ownerID == activeOwnerID }
    }

    /// Audio still in the inbox failed to import. A PDF or link only needs
    /// attention after sending it failed; until then it is simply on its way.
    var sharesNeedingAttention: [ShareInboxStore.Item] {
        availableSharedItems.filter {
            $0.resolvedKind == .audio || pendingSharedErrors[$0.id] != nil
        }
    }

    /// Only for a deliberate tap on a share that could not be processed.
    func discardSharedItem(_ item: ShareInboxStore.Item) {
        completeSharedDocument(item)
    }

    func sharedDocuments(ownedBy ownerID: String) -> [ShareInboxStore.Item] {
        pendingSharedItems.filter { $0.resolvedKind != .audio && $0.ownerID == ownerID }
    }

    /// Saves who owns each unowned PDF and link before anything is sent. As with
    /// recordings, the intended owner is saved first: if a write fails, the claim
    /// retries for this account and never passes to a later one.
    func claimSharedDocuments() {
        guard let ownerID = activeOwnerID, let shareInbox else { return }
        let intendedOwnerID = localAccountDefaults.string(forKey: Self.pendingShareClaimOwnerIDKey)
        let unclaimed = pendingSharedItems.indices.filter {
            pendingSharedItems[$0].resolvedKind != .audio && pendingSharedItems[$0].ownerID == nil
        }
        guard intendedOwnerID != nil || !unclaimed.isEmpty else { return }
        let claimOwnerID = intendedOwnerID ?? ownerID
        localAccountDefaults.set(claimOwnerID, forKey: Self.pendingShareClaimOwnerIDKey)
        let autoTranscribe = AutoTranscribePreference(defaults: localAccountDefaults)
            .isEnabled(ownerID: claimOwnerID)
        var claimedAll = true
        for index in unclaimed {
            var claimed = pendingSharedItems[index]
            claimed.ownerID = claimOwnerID
            claimed.autoTranscribeRequested = autoTranscribe
            do {
                try shareInbox.update(claimed)
                pendingSharedItems[index] = claimed
            } catch {
                claimedAll = false
            }
        }
        if claimedAll {
            localAccountDefaults.removeObject(forKey: Self.pendingShareClaimOwnerIDKey)
        }
    }

    /// Permission was revoked while this link was being sent, so it stays manual.
    func markSharedDocumentManual(_ itemID: UUID) {
        guard let index = pendingSharedItems.firstIndex(where: { $0.id == itemID }) else { return }
        var updated = pendingSharedItems[index]
        updated.autoTranscribeRequested = false
        pendingSharedItems[index] = updated
        try? shareInbox?.update(updated)
    }

    /// With no App Group container, the extension cannot have staged anything. A
    /// container that exists but cannot be read still throws, so the caller retries.
    private func shareInboxIfAvailable() throws -> ShareInboxStore? {
        do {
            return try resolvedShareInbox()
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return nil
        }
    }

    private func migrateSharedDocuments(from clerkID: String, to userID: String) throws {
        guard let inbox = try shareInboxIfAvailable() else { return }
        for var item in try inbox.pendingItems() where item.ownerID == clerkID {
            item.ownerID = userID
            try inbox.update(item)
            if let index = pendingSharedItems.firstIndex(where: { $0.id == item.id }) {
                pendingSharedItems[index] = item
            }
        }
        if localAccountDefaults.string(forKey: Self.pendingShareClaimOwnerIDKey) == clerkID {
            localAccountDefaults.set(userID, forKey: Self.pendingShareClaimOwnerIDKey)
        }
    }

    private func deleteSharedDocuments(ownedBy ownerID: String) throws {
        guard let inbox = try shareInboxIfAvailable() else { return }
        // Includes audio that carries a direct upload, which has an owner too.
        for item in try inbox.pendingItems() where item.ownerID == ownerID {
            try inbox.remove(item)
            pendingSharedItems.removeAll { $0.id == item.id }
            pendingSharedErrors[item.id] = nil
        }
    }

    /// The server has the item, so the inbox copy is no longer the only one.
    func completeSharedDocument(_ item: ShareInboxStore.Item) {
        do {
            try shareInbox?.remove(item)
            pendingSharedItems.removeAll { $0.id == item.id }
            pendingSharedErrors[item.id] = nil
        } catch {
            pendingSharedErrors[item.id] = error.localizedDescription
        }
    }

    func failSharedDocument(_ item: ShareInboxStore.Item, message: String) {
        pendingSharedErrors[item.id] = message
    }

    /// Starts capture from the visible app. This path may present the system's
    /// microphone permission prompt and continues recording even if the person
    /// has chosen not to show Live Activities.
    func start(contentType: String) {
        guard prepareToStart() else { return }
        if simulatesCapture {
            // Preserve deterministic synchronous state transitions for unit and
            // UI tests; ActivityKit setup can still complete independently.
            startSimulatedRecording(contentType: contentType)
            Task {
                _ = await startActivityAfterCapture(requiresLiveActivity: false)
            }
            return
        }
        Task {
            _ = await completeStart(
                contentType: contentType,
                requiresLiveActivity: false,
                mayRequestPermission: true
            )
        }
    }

    /// The Action Button, Shortcuts, widget, and Control Center all call this
    /// toggle. AudioRecordingIntent requires an accompanying Live Activity, so
    /// this path refuses to start invisibly when Live Activities are disabled.
    func toggleFromSystem(contentType: String = "voice_memo") async -> SystemCaptureOutcome {
        if isRecording || activeRecordingID != nil {
            return await stopFromSystem()
        }
        guard prepareToStart() else {
            return .failed(errorMessage ?? "A recording is already being prepared.")
        }
        return await completeStart(
            contentType: contentType,
            requiresLiveActivity: true,
            mayRequestPermission: false
        )
    }

    func stopFromSystem() async -> SystemCaptureOutcome {
        guard isRecording || activeRecordingID != nil else { return .alreadyStopped }
        let recordingID = activeRecordingID
        let finalDuration = finalizeRecording(
            state: .ready,
            message: "Saved on this iPhone",
            endActivityAutomatically: false
        )
        await endLiveActivity(recordingID: recordingID, finalDuration: finalDuration)
        return .stopped
    }

    private func prepareToStart() -> Bool {
        guard !isRecording, !isStarting else { return false }
        retryRestorationIfNeeded()
        guard store != nil else {
            errorMessage = "Secure recording storage is unavailable. Unlock this iPhone and try again."
            return false
        }
        if let directoryURL = store?.directoryURL,
           let bytesAvailable = availableCapacity(directoryURL),
           bytesAvailable < Self.minimumStartCapacityBytes {
            storageIsLow = true
            errorMessage = "Free at least 100 MB of storage before starting a recording."
            return false
        }

        isStarting = true
        errorMessage = nil
        statusMessage = nil
        storageIsLow = false
        permissionDenied = false
        return true
    }

    private func completeStart(
        contentType: String,
        requiresLiveActivity: Bool,
        mayRequestPermission: Bool
    ) async -> SystemCaptureOutcome {
        if requiresLiveActivity, !activityManager.areActivitiesEnabled {
            isStarting = false
            errorMessage = "Live Activities must be enabled for Quick Record."
            return .liveActivitiesDisabled
        }

        if simulatesCapture {
            startSimulatedRecording(contentType: contentType)
            return await startActivityAfterCapture(requiresLiveActivity: requiresLiveActivity)
        }

        let permission = AVAudioApplication.shared.recordPermission
        if !mayRequestPermission, permission != .granted {
            isStarting = false
            permissionDenied = true
            errorMessage = "Open Media Tools once and allow microphone access before using Quick Record."
            return .microphonePermissionRequired
        }

        let granted: Bool
        switch permission {
        case .granted:
            granted = true
        case .denied:
            granted = false
        case .undetermined:
            granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { permissionGranted in
                    continuation.resume(returning: permissionGranted)
                }
            }
        @unknown default:
            granted = false
        }

        guard granted else {
            isStarting = false
            permissionDenied = true
            errorMessage = "Microphone access is required to record. You can enable it in Settings."
            return .microphonePermissionRequired
        }

        startRecording(session: AVAudioSession.sharedInstance(), contentType: contentType)
        return await startActivityAfterCapture(requiresLiveActivity: requiresLiveActivity)
    }

    private func startActivityAfterCapture(requiresLiveActivity: Bool) async -> SystemCaptureOutcome {
        guard isRecording,
              let activeRecordingID,
              let recording = pendingRecordings.first(where: { $0.id == activeRecordingID })
        else {
            return .failed(errorMessage ?? "The audio session did not begin.")
        }

        guard activityManager.areActivitiesEnabled else {
            // A visible in-app recording remains valid without a Live Activity.
            guard requiresLiveActivity else { return .started }
            let finalDuration = finalizeRecording(
                state: .ready,
                message: "Saved after Live Activities became unavailable",
                endActivityAutomatically: false
            )
            await activityManager.end(
                recordingID: recording.id,
                finalDuration: finalDuration
            )
            return .liveActivitiesDisabled
        }

        do {
            try await activityManager.start(for: recording)
            guard isRecording, activeRecordingID == recording.id else {
                // Activity.request can suspend. A stop may complete while it is
                // in flight, so immediately clean up only that stale activity.
                let finalDuration = pendingRecordings.first { $0.id == recording.id }?.duration ?? 0
                await activityManager.end(
                    recordingID: recording.id,
                    finalDuration: finalDuration
                )
                return .stopped
            }
            // Activity.request can suspend long enough for the person to pause
            // or for iOS to interrupt capture. Reconcile the newly created
            // activity with the latest state instead of leaving it "running."
            await activityManager.update(
                recordingID: recording.id,
                isPaused: isPaused,
                isInterrupted: isInterrupted,
                duration: duration
            )
            return .started
        } catch {
            let message = "The recording indicator could not start: \(error.localizedDescription)"
            guard isRecording, activeRecordingID == recording.id else {
                let finalDuration = pendingRecordings.first { $0.id == recording.id }?.duration ?? 0
                await activityManager.end(
                    recordingID: recording.id,
                    finalDuration: finalDuration
                )
                return .stopped
            }
            if requiresLiveActivity {
                let finalDuration = finalizeRecording(
                    state: .ready,
                    message: "Saved after Quick Record could not start",
                    endActivityAutomatically: false
                )
                await activityManager.end(
                    recordingID: recording.id,
                    finalDuration: finalDuration
                )
                errorMessage = message
                return .failed(message)
            }
            statusMessage = "Recording securely on this iPhone"
            return .started
        }
    }

    func stop() {
        _ = finalizeRecording(state: .ready, message: "Saved on this iPhone")
    }

    @discardableResult
    func pause() -> Bool {
        guard captureState == .recording else { return false }
        if let audioRecorder {
            duration = max(duration, audioRecorder.currentTime)
            audioRecorder.pause()
        }
        checkpointActiveRecordingIfNeeded(force: true)
        timer?.invalidate()
        timer = nil
        captureState = .paused
        audioLevel = 0
        statusMessage = "Recording paused"
        updateLiveActivity()
        return true
    }

    @discardableResult
    func resume() -> Bool {
        guard captureState == .paused else { return false }

        do {
            if !simulatesCapture {
                try AVAudioSession.sharedInstance().setActive(true)
                guard let audioRecorder, audioRecorder.record() else {
                    throw RecordingCoordinatorError.couldNotResume
                }
            }
            captureState = .recording
            statusMessage = "Recording resumed"
            startMeterTimer()
            updateLiveActivity()
            return true
        } catch {
            errorMessage = "Recording is still paused and could not resume: \(error.localizedDescription)"
            return false
        }
    }

    func discard(_ recording: LocalRecording) {
        guard recording.id != activeRecordingID,
              !recording.isUploadInProgress,
              let store else { return }
        do {
            try store.deleteFile(for: recording)
            pendingRecordings.removeAll { $0.id == recording.id }
            try persistPendingRecordings()
        } catch {
            errorMessage = "The recording could not be removed: \(error.localizedDescription)"
        }
    }

    /// Checks an unfinalized recording again on a deliberate tap. A file that now
    /// passes, or one only the server rejected, becomes uploadable; one that still
    /// fails stays exactly as it was, because nothing here may lose a recording.
    func recheckInvalidRecording(_ recordingID: UUID) -> Result<LocalRecording, RecordingIntegrityError> {
        guard let current = recording(withID: recordingID), let store else {
            return .failure(.emptyFile)
        }
        guard current.state == .invalid else { return .success(current) }
        switch RecordingIntegrityValidator.validate(url: store.fileURL(for: current)) {
        case .success:
            updateRecording(recordingID) { recording in
                recording.state = .ready
                recording.lastError = nil
            }
            return .success(recording(withID: recordingID) ?? current)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// A 202 response proves that the server created a job, not that the audio
    /// can be decoded. Keep the only known-good local source until that job
    /// reaches a successful terminal state.
    func markServerAccepted(_ recordingID: UUID, transcriptionID: String) {
        updateRecording(recordingID) { recording in
            recording.state = .serverProcessing
            recording.remoteTranscriptionID = transcriptionID
            recording.lastError = nil
            recording.uploadProgress = 1
            recording.uploadTaskIdentifier = nil
        }
        statusMessage = "Upload complete. Device copy retained while transcription runs."
    }

    func markServerCompleted(_ recordingID: UUID) {
        guard let current = recording(withID: recordingID), let store else { return }
        do {
            try store.deleteFile(for: current)
            pendingRecordings.removeAll { $0.id == current.id }
            try persistPendingRecordings()
            statusMessage = "Transcription complete; device copy removed"
        } catch {
            errorMessage = "Transcription completed, but its device copy could not be removed."
        }
    }

    func markServerFailed(_ recordingID: UUID, message: String, invalidSource: Bool) {
        updateRecording(recordingID) { recording in
            recording.state = invalidSource ? .invalid : .uploadFailed
            recording.lastError = message
            recording.uploadProgress = nil
            recording.uploadTaskIdentifier = nil
        }
    }

    func markUploadFailed(_ recording: LocalRecording, message: String) {
        guard let index = pendingRecordings.firstIndex(where: { $0.id == recording.id }) else { return }
        pendingRecordings[index].state = .uploadFailed
        pendingRecordings[index].lastError = message
        do {
            try persistPendingRecordings()
        } catch {
            errorMessage = "The upload failed and its recovery state could not be saved."
        }
    }

    func importRecording(
        from sourceURL: URL,
        contentType: String,
        shareID: UUID? = nil,
        originalName: String? = nil,
        autoTranscribe: Bool = false,
        ownerID: String? = nil,
        directUpload: ShareInboxStore.DirectUpload? = nil
    ) throws -> LocalRecording {
        guard let store else {
            throw RecordingCoordinatorError.storageUnavailable
        }
        if let shareID, let existing = pendingRecordings.first(where: { $0.id == shareID }) {
            return existing
        }
        var recording = try store.importRecording(
            from: sourceURL,
            contentType: contentType,
            ownerID: ownerID ?? activeOwnerID,
            id: shareID ?? UUID(),
            originalName: originalName,
            autoTranscribeRequested: autoTranscribe
        )
        if case .failure(let validationError) = RecordingIntegrityValidator.validate(
            url: store.fileURL(for: recording)
        ) {
            try? store.deleteFile(for: recording)
            throw RecordingCoordinatorError.invalidRecording(
                validationError.errorDescription ?? "The selected audio file is invalid."
            )
        }
        if let directUpload {
            recording.state = directUpload.uploadFinished == true ? .finalizingUpload : .uploading
            recording.uploadProgress = 0
            recording.uploadObjectKey = directUpload.objectKey
            recording.uploadSizeBytes = directUpload.sizeBytes
            recording.uploadMimeType = directUpload.mimeType
            recording.shareUploadSessionIdentifier = directUpload.sessionIdentifier
        }
        pendingRecordings.insert(recording, at: 0)
        do {
            try persistPendingRecordings()
            return recording
        } catch {
            try? store.deleteFile(for: recording)
            pendingRecordings.removeAll { $0.id == recording.id }
            throw error
        }
    }

    func markWaitingForUpload(_ recordingID: UUID, message: String? = nil) {
        updateRecording(recordingID) { recording in
            recording.state = .waitingForUpload
            recording.lastError = message
            recording.uploadProgress = nil
            recording.uploadTaskIdentifier = nil
            recording.shareUploadSessionIdentifier = nil
        }
    }

    /// Permission was revoked, or the person is discarding, while this recording
    /// was queued. It goes back to a saved recording only a deliberate tap can send.
    func markReadyAfterConsentRevoked(_ recordingID: UUID) {
        updateRecording(recordingID) { recording in
            recording.state = .ready
            recording.lastError = nil
            recording.uploadProgress = nil
            recording.uploadTaskIdentifier = nil
            recording.shareUploadSessionIdentifier = nil
            recording.autoTranscribeRequested = false
        }
    }

    func markUploadStarted(
        _ recordingID: UUID,
        objectKey: String,
        sizeBytes: Int64,
        mimeType: String,
        taskIdentifier: Int
    ) {
        guard recording(withID: recordingID)?.canUpload == true
                || recording(withID: recordingID)?.state == .waitingForUpload
        else { return }
        updateRecording(recordingID) { recording in
            recording.state = .uploading
            recording.lastError = nil
            recording.uploadProgress = 0
            recording.uploadObjectKey = objectKey
            recording.uploadSizeBytes = sizeBytes
            recording.uploadMimeType = mimeType
            recording.uploadTaskIdentifier = taskIdentifier
            recording.shareUploadSessionIdentifier = nil
        }
    }

    func updateUploadProgress(_ recordingID: UUID, progress: Double) {
        guard let index = pendingRecordings.firstIndex(where: { $0.id == recordingID }) else { return }
        let normalized = min(max(progress, 0), 1)
        let previousBucket = Int(((pendingRecordings[index].uploadProgress ?? 0) * 20).rounded(.down))
        let nextBucket = Int((normalized * 20).rounded(.down))
        pendingRecordings[index].uploadProgress = normalized
        guard previousBucket != nextBucket || normalized == 1 else { return }
        try? persistPendingRecordings()
    }

    func markUploadFinalizing(_ recordingID: UUID, message: String? = nil) {
        guard let state = recording(withID: recordingID)?.state,
              state == .uploading || state == .finalizingUpload
        else { return }
        updateRecording(recordingID) { recording in
            recording.state = .finalizingUpload
            recording.lastError = message
            recording.uploadProgress = 1
            recording.uploadTaskIdentifier = nil
        }
    }

    func markUploadFailed(_ recordingID: UUID, message: String) {
        updateRecording(recordingID) { recording in
            recording.state = .uploadFailed
            recording.lastError = message
            recording.uploadTaskIdentifier = nil
        }
    }

    private func updateRecording(
        _ recordingID: UUID,
        mutation: (inout LocalRecording) -> Void
    ) {
        guard let index = pendingRecordings.firstIndex(where: { $0.id == recordingID }) else { return }
        mutation(&pendingRecordings[index])
        do {
            try persistPendingRecordings()
        } catch {
            errorMessage = "The recording is safe, but its upload status could not be saved."
        }
    }

    private func startRecording(session: AVAudioSession, contentType: String) {
        defer { isStarting = false }
        guard let store else { return }

        do {
            let bluetoothInput: AVAudioSession.CategoryOptions
            #if compiler(>=6.2)
            bluetoothInput = .allowBluetoothHFP
            #else
            bluetoothInput = .allowBluetooth
            #endif
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, bluetoothInput]
            )
            try session.setActive(true)
        } catch {
            errorMessage = "Could not start the audio session: \(error.localizedDescription)"
            return
        }

        var recording: LocalRecording?
        do {
            let newRecording = store.makeRecording(
                contentType: contentType,
                ownerID: activeOwnerID,
                autoTranscribeRequested: autoTranscribeEnabledForNewRecordings
            )
            recording = newRecording
            pendingRecordings.insert(newRecording, at: 0)
            try persistPendingRecordings()

            let url = store.fileURL(for: newRecording)
            let settings: [String: Any] = [
                // Linear PCM in CAF remains structurally recoverable if iOS
                // terminates the app before AVAudioRecorder.stop() can run.
                // 16 kHz mono is the speech model's target bandwidth and uses
                // about 115 MB per hour before the server normalizes to MP3.
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16_000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let replacementRecorder = try AVAudioRecorder(url: url, settings: settings)
            replacementRecorder.isMeteringEnabled = true
            guard replacementRecorder.record() else {
                throw RecordingCoordinatorError.couldNotStart
            }
            try store.protectRecordingFile(newRecording)

            audioRecorder = replacementRecorder
            activeRecordingID = newRecording.id
            captureState = .recording
            stateBeforeInterruption = nil
            duration = 0
            lastCheckpointedDuration = 0
            lastStorageCheckDuration = 0
            audioLevel = 0
            levelMeter = LiveLevelMeter()
            statusMessage = "Recording securely on this iPhone"
            startMeterTimer()
        } catch {
            audioRecorder = nil
            if let recording {
                pendingRecordings.removeAll { $0.id == recording.id }
                try? store.deleteFile(for: recording)
                try? persistPendingRecordings()
            }
            errorMessage = "Recording failed: \(error.localizedDescription)"
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// UI tests need to exercise the complete persistence experience without
    /// depending on whichever microphone device happens to be connected to the
    /// Mac running Simulator. This branch is compiled only into Debug builds.
    private func startSimulatedRecording(contentType: String) {
        defer { isStarting = false }
        guard let store else { return }

        var recording: LocalRecording?
        do {
            let newRecording = store.makeRecording(
                contentType: contentType,
                ownerID: activeOwnerID,
                autoTranscribeRequested: autoTranscribeEnabledForNewRecordings
            )
            recording = newRecording
            // A tiny CAF fixture exercises the crash-recovery validator without
            // depending on Simulator microphone hardware.
            try Self.simulatedCAFData.write(
                to: store.fileURL(for: newRecording),
                options: .atomic
            )
            try store.protectRecordingFile(newRecording)
            pendingRecordings.insert(newRecording, at: 0)
            try persistPendingRecordings()

            activeRecordingID = newRecording.id
            captureState = .recording
            stateBeforeInterruption = nil
            duration = 0
            lastCheckpointedDuration = 0
            lastStorageCheckDuration = 0
            audioLevel = 0.35
            levelMeter = LiveLevelMeter()
            statusMessage = "Recording securely on this iPhone"
            startMeterTimer()
        } catch {
            if let recording {
                pendingRecordings.removeAll { $0.id == recording.id }
                try? store.deleteFile(for: recording)
                try? persistPendingRecordings()
            }
            errorMessage = "Recording failed: \(error.localizedDescription)"
        }
    }

    private func startMeterTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateMeters()
            }
        }
    }

    private func updateMeters() {
        guard captureState == .recording else { return }
        if simulatesCapture {
            duration += 0.1
            // A believable speech envelope for simulator runs, which have no microphone.
            audioLevel = 0.02 + (0.3 * CGFloat(abs(sin(duration * 4.3) * cos(duration * 1.7))))
            levelMeter.append(linearLevel: audioLevel)
            checkpointActiveRecordingIfNeeded()
            enforceStorageSafetyIfNeeded()
            return
        }
        guard let audioRecorder else { return }
        audioRecorder.updateMeters()
        duration = audioRecorder.currentTime
        let power = max(-60, min(0, audioRecorder.averagePower(forChannel: 0)))
        audioLevel = CGFloat(pow(10, power / 20))
        levelMeter.append(linearLevel: audioLevel)
        checkpointActiveRecordingIfNeeded()
        enforceStorageSafetyIfNeeded()
    }

    /// Long recordings should fail safe while there is still room to finalize
    /// their audio container and manifest. Capacity is checked infrequently so
    /// metering remains lightweight, and the saved recording stays uploadable.
    func enforceStorageSafetyIfNeeded(force: Bool = false) {
        guard captureState == .recording,
              force || duration - lastStorageCheckDuration >= 10,
              let directoryURL = store?.directoryURL
        else { return }

        lastStorageCheckDuration = duration
        guard let bytesAvailable = availableCapacity(directoryURL),
              bytesAvailable < Self.criticalRecordingCapacityBytes
        else { return }

        storageIsLow = true
        _ = finalizeRecording(
            state: .ready,
            message: "Recording stopped and saved because this iPhone is low on storage."
        )
    }

    /// A small manifest checkpoint makes the elapsed time useful after an
    /// unexpected termination without rewriting JSON on every meter tick.
    private func checkpointActiveRecordingIfNeeded(force: Bool = false) {
        guard let activeRecordingID,
              force || duration - lastCheckpointedDuration >= 10,
              let index = pendingRecordings.firstIndex(where: { $0.id == activeRecordingID })
        else { return }

        pendingRecordings[index].duration = duration
        lastCheckpointedDuration = duration
        try? persistPendingRecordings()
    }

    @discardableResult
    private func finalizeRecording(
        state: LocalRecordingState,
        message: String,
        endActivityAutomatically: Bool = true
    ) -> TimeInterval {
        guard isRecording || activeRecordingID != nil else { return duration }
        let recordingIDToEnd = activeRecordingID
        if let audioRecorder {
            duration = max(duration, audioRecorder.currentTime)
            audioRecorder.stop()
        }
        audioRecorder = nil
        timer?.invalidate()
        timer = nil
        captureState = .idle
        stateBeforeInterruption = nil
        audioLevel = 0
        var finalStatusMessage = message

        if let activeRecordingID,
           let index = pendingRecordings.firstIndex(where: { $0.id == activeRecordingID }),
           let store {
            pendingRecordings[index].duration = duration
            let validation = RecordingIntegrityValidator.validate(
                url: store.fileURL(for: pendingRecordings[index])
            )
            switch validation {
            case .success:
                pendingRecordings[index].state = state
                pendingRecordings[index].lastError = state == .interrupted ? message : nil
            case .failure:
                pendingRecordings[index].state = .invalid
                pendingRecordings[index].lastError = Self.invalidRecordingMessage
                finalStatusMessage = Self.invalidRecordingMessage
            }
            do {
                try persistPendingRecordings()
            } catch {
                errorMessage = "The recording was saved, but its recovery information could not be updated."
            }
        }
        self.activeRecordingID = nil
        statusMessage = finalStatusMessage
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let finalDuration = duration
        // The saved LocalRecording retains the completed duration. `duration`
        // is the live capture clock, so carrying it into the ready state makes
        // the next recording look as though it has already been running.
        duration = 0
        if endActivityAutomatically {
            Task {
                await endLiveActivity(
                    recordingID: recordingIDToEnd,
                    finalDuration: finalDuration
                )
            }
        }
        onSavedRecordingsChanged?()
        return finalDuration
    }

    /// Files protected until first unlock cannot be read after a restart until
    /// the person unlocks, and a background launch can arrive before that. Any
    /// later point can finish the restore, so the app tries again at unlock and
    /// whenever it next needs the list.
    func retryRestorationIfNeeded() {
        guard !hasRestoredManifest else { return }
        if store == nil, let recovered = try? RecordingStore() {
            store = recovered
        }
        restorePendingRecordings()
    }

    private func restorePendingRecordings() {
        let restoredLate = hasAttemptedRestoration
        hasAttemptedRestoration = true
        guard let store, !hasRestoredManifest else { return }
        do {
            // This launch's own recordings are the newest copy of themselves, and
            // one of them may be capturing right now. Recovery must leave them alone.
            let journaled = try store.loadUnmergedRecordings()
            var known = Set(pendingRecordings.map(\.id))
            var adopted = journaled.filter { !known.contains($0.id) }
            var recoveredAny = recoverInterruptedRecordings(&adopted, store: store)
            pendingRecordings = Self.newestFirst(pendingRecordings + adopted)
            unmergedRecordingIDs.formUnion(journaled.map(\.id))
            known.formUnion(adopted.map(\.id))

            var saved = try store.loadRecordings().filter { !known.contains($0.id) }
            recoveredAny = recoverInterruptedRecordings(&saved, store: store) || recoveredAny
            let merged = Self.newestFirst(pendingRecordings + saved)
            if recoveredAny || !known.isEmpty {
                // The manifest is written before the unmerged files go, so a
                // termination between the two only repeats this same merge.
                try store.saveRecordings(merged)
            }
            try store.removeAllUnmergedRecordings()
            pendingRecordings = merged
            unmergedRecordingIDs = []
            hasRestoredManifest = true
            if errorMessage == Self.restorationPendingMessage
                || errorMessage == Self.storageUnavailableMessage {
                errorMessage = nil
            }
            if activeOwnerID != nil {
                claimUnownedRecordings()
            }
            if recoveredAny, activeRecordingID == nil {
                statusMessage = pendingRecordings.contains { $0.state == .invalid }
                    ? "A recording needs recovery and was not uploaded"
                    : "Recovered and verified an interrupted recording"
                Task { [activityManager] in
                    await activityManager.end(recordingID: nil, finalDuration: 0)
                }
            }
            if restoredLate {
                // Not inline: this can run in the middle of saving another recording.
                Task { @MainActor [weak self] in
                    self?.onRecordingsRestored?()
                }
            }
        } catch {
            errorMessage = Self.restorationPendingMessage
        }
    }

    @discardableResult
    private func recoverInterruptedRecordings(
        _ recordings: inout [LocalRecording],
        store: RecordingStore
    ) -> Bool {
        var recoveredAny = false
        for index in recordings.indices {
            let recording = recordings[index]
            guard recording.state == .recording || recording.canUpload else { continue }
            switch RecordingIntegrityValidator.validate(url: store.fileURL(for: recording)) {
            case .success where recording.state == .recording:
                recordings[index].state = .interrupted
                recordings[index].lastError =
                    "Recovered and verified after Media Tools stopped unexpectedly."
                recoveredAny = true
            case .failure:
                recordings[index].state = .invalid
                recordings[index].lastError = Self.invalidRecordingMessage
                recoveredAny = true
            default:
                break
            }
        }
        return recoveredAny
    }

    private static func newestFirst(_ recordings: [LocalRecording]) -> [LocalRecording] {
        recordings.sorted { $0.createdAt > $1.createdAt }
    }

    private static let restorationPendingMessage =
        "Earlier recordings are safe but not available yet. They will come back after this iPhone unlocks."
    private static let storageUnavailableMessage =
        "Media Tools could not prepare secure recording storage."

    private static let invalidRecordingMessage =
        "This older recording ended before its audio index was saved. Export and keep the original file for a best-effort recovery attempt on a computer."

    #if DEBUG
    /// The two shapes on a real iPhone: a recording recovered after an interruption,
    /// never flagged for automatic transcription, and an old `.m4a` with no index.
    private func seedNeedsYouFixtures() {
        guard let store else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let day: (Int) -> Date = { calendar.date(from: DateComponents(year: 2026, month: 8, day: $0, hour: 19, minute: 30)) ?? Date() }
        let interrupted = LocalRecording(
            id: UUID(), filename: "needs-you-interrupted.caf", originalFilename: nil, createdAt: day(26),
            duration: 5_352, contentType: "general", state: .interrupted,
            lastError: "Recovered and verified after Media Tools stopped unexpectedly."
        )
        let invalid = LocalRecording(
            id: UUID(), filename: "needs-you-invalid.m4a", originalFilename: nil, createdAt: day(21),
            duration: 1_705, contentType: "general", state: .invalid,
            lastError: Self.invalidRecordingMessage
        )
        // An ISO media header and audio bytes with no `moov` box, as a crash leaves it.
        let unfinalized = Data([0, 0, 0, 16]) + Data("ftypM4A ".utf8) + Data(count: 4)
            + Data([0, 0, 0, 16]) + Data("mdat".utf8) + Data(count: 8)
        try? Self.simulatedCAFData.write(to: store.fileURL(for: interrupted))
        try? unfinalized.write(to: store.fileURL(for: invalid))
        try? store.saveRecordings([interrupted, invalid])
    }
    #endif

    private static let simulatedCAFData: Data = {
        func chunk(_ type: String, payload: Data) -> Data {
            let size = UInt64(payload.count)
            var data = Data(type.utf8)
            data.append(contentsOf: (0..<8).reversed().map {
                UInt8((size >> UInt64($0 * 8)) & 0xff)
            })
            data.append(payload)
            return data
        }
        var description = Data(count: 32)
        description.replaceSubrange(8..<12, with: Data("lpcm".utf8))
        return Data("caff".utf8) + Data([0x00, 0x01, 0x00, 0x00])
            + chunk("desc", payload: description)
            + chunk("data", payload: Data([0, 0, 0, 0, 1, 0]))
    }()

    private func persistPendingRecordings() throws {
        guard let store else { return }
        retryRestorationIfNeeded()
        if hasRestoredManifest {
            try store.saveRecordings(pendingRecordings)
            return
        }
        // The manifest stays untouched until it has been read. A recording made
        // in this window lives in its own file, so it survives a termination too.
        let currentIDs = Set(pendingRecordings.map(\.id))
        for id in unmergedRecordingIDs.subtracting(currentIDs) {
            try store.removeUnmergedRecording(id: id)
        }
        for recording in pendingRecordings {
            try store.saveUnmergedRecording(recording)
        }
        unmergedRecordingIDs = currentIDs
    }

    private func observeProtectedData() {
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.retryRestorationIfNeeded()
                }
            }
        )
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        notificationObservers.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleInterruption(notification)
                }
            }
        )
        notificationObservers.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleRouteChange(notification)
                }
            }
        )
        notificationObservers.append(
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording else { return }
                    self.finalizeRecording(
                        state: .interrupted,
                        message: "Recording stopped because the audio system restarted."
                    )
                }
            }
        )
    }

    private func handleInterruption(_ notification: Notification) {
        guard isRecording,
              let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        switch type {
        case .began:
            guard captureState != .interrupted else { return }
            stateBeforeInterruption = captureState
            if let audioRecorder {
                duration = max(duration, audioRecorder.currentTime)
            }
            checkpointActiveRecordingIfNeeded(force: true)
            timer?.invalidate()
            timer = nil
            captureState = .interrupted
            audioLevel = 0
            statusMessage = "Recording paused by another audio source"
            updateLiveActivity()
        case .ended:
            let previousState = stateBeforeInterruption
            stateBeforeInterruption = nil
            if previousState == .paused {
                captureState = .paused
                statusMessage = "Recording paused"
                updateLiveActivity()
                return
            }
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            guard options.contains(.shouldResume), let audioRecorder else {
                finalizeRecording(
                    state: .interrupted,
                    message: "Recording stopped after an audio interruption."
                )
                return
            }
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                guard audioRecorder.record() else { throw RecordingCoordinatorError.couldNotResume }
                captureState = .recording
                statusMessage = "Recording resumed"
                startMeterTimer()
                updateLiveActivity()
            } catch {
                finalizeRecording(
                    state: .interrupted,
                    message: "Recording could not resume after an interruption."
                )
            }
        @unknown default:
            finalizeRecording(
                state: .interrupted,
                message: "Recording stopped after an unknown audio interruption."
            )
        }
    }

    private func updateLiveActivity() {
        guard let activeRecordingID else { return }
        let paused = isPaused
        let interrupted = isInterrupted
        let elapsedDuration = duration
        let previousUpdate = activityUpdateTask
        activityUpdateTask = Task { [activityManager] in
            await previousUpdate?.value
            await activityManager.update(
                recordingID: activeRecordingID,
                isPaused: paused,
                isInterrupted: interrupted,
                duration: elapsedDuration
            )
        }
    }

    private func endLiveActivity(recordingID: UUID?, finalDuration: TimeInterval) async {
        let pendingUpdate = activityUpdateTask
        activityUpdateTask = nil
        await pendingUpdate?.value
        await activityManager.end(recordingID: recordingID, finalDuration: finalDuration)
    }

    private func handleRouteChange(_ notification: Notification) {
        guard captureState == .recording,
              let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else { return }
        switch reason {
        case .oldDeviceUnavailable:
            statusMessage = "Audio input changed; recording is continuing"
        case .newDeviceAvailable:
            statusMessage = "New audio input connected"
        default:
            break
        }
    }
}

private enum RecordingCoordinatorError: LocalizedError {
    case couldNotStart
    case couldNotResume
    case storageUnavailable
    case manifestUnavailable
    case invalidRecording(String)

    var errorDescription: String? {
        switch self {
        case .couldNotStart:
            return "The recorder could not start."
        case .couldNotResume:
            return "The recorder could not resume."
        case .storageUnavailable:
            return "Secure recording storage is unavailable."
        case .manifestUnavailable:
            return "Earlier recordings are not available until this iPhone unlocks."
        case .invalidRecording(let message):
            return message
        }
    }
}

/// NotificationCenter retains block observers, so the bag owns and unregisters
/// their opaque tokens without making RecordingCoordinator's actor-isolated
/// deinitializer reach across isolation boundaries.
private final class NotificationObserverBag {
    private var observers: [NSObjectProtocol] = []

    func append(_ observer: NSObjectProtocol) {
        observers.append(observer)
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
