import AVFoundation
import Foundation
import Observation
import SwiftUI

/// Owns microphone capture for the whole app rather than for one SwiftUI view.
/// This is what allows an active recording to survive tab changes, screen lock,
/// and ordinary backgrounding. System controls and App Intents call this same
/// coordinator so every entry point shares one recording lifecycle.
@MainActor
@Observable
final class RecordingCoordinator {
    static let shared = RecordingCoordinator()

    private(set) var isRecording = false
    private(set) var isStarting = false
    private(set) var isInterrupted = false
    private(set) var pendingRecordings: [LocalRecording] = []
    private(set) var duration: TimeInterval = 0
    private(set) var audioLevel: CGFloat = 0
    private(set) var statusMessage: String?
    private(set) var storageIsLow = false
    var errorMessage: String?
    var permissionDenied = false

    private var audioRecorder: AVAudioRecorder?
    private var activeRecordingID: UUID?
    private var timer: Timer?
    private var lastCheckpointedDuration: TimeInterval = 0
    private var lastStorageCheckDuration: TimeInterval = 0
    private let notificationObservers = NotificationObserverBag()
    private let store: RecordingStore?
    private let simulatesCapture: Bool
    private let activityManager: RecordingActivityManaging
    private let availableCapacity: (URL) -> Int64?

    static let minimumStartCapacityBytes: Int64 = 100 * 1_024 * 1_024
    static let criticalRecordingCapacityBytes: Int64 = 50 * 1_024 * 1_024

    init(
        store: RecordingStore? = nil,
        simulatesCapture: Bool? = nil,
        activityManager: RecordingActivityManaging? = nil,
        availableCapacity: @escaping (URL) -> Int64? = RecordingStorageCapacity.available
    ) {
        #if DEBUG
        self.simulatesCapture = simulatesCapture
            ?? ProcessInfo.processInfo.arguments.contains("-ui-test-simulated-recording")
        #else
        self.simulatesCapture = false
        #endif
        self.activityManager = activityManager ?? RecordingActivityManager.shared
        self.availableCapacity = availableCapacity

        if let store {
            self.store = store
        } else {
            do {
                self.store = try RecordingStore()
            } catch {
                self.store = nil
                errorMessage = "Media Tools could not prepare secure recording storage."
            }
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ui-test-reset-recordings") {
            try? self.store?.deleteAllRecordings()
        }
        #endif
        restorePendingRecordings()
        observeAudioSession()
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
        pendingRecordings.filter { $0.state != .recording }
    }

    func fileURL(for recording: LocalRecording) -> URL? {
        store?.fileURL(for: recording)
    }

    func recording(withID id: UUID) -> LocalRecording? {
        pendingRecordings.first { $0.id == id }
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
        await activityManager.end(recordingID: recordingID, finalDuration: finalDuration)
        return .stopped
    }

    private func prepareToStart() -> Bool {
        guard !isRecording, !isStarting else { return false }
        guard store != nil else {
            errorMessage = "Secure recording storage is unavailable. Restart Media Tools and try again."
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

    /// Remove the device copy only after the server has accepted the recording
    /// and created its durable transcription job.
    func markUploaded(_ recording: LocalRecording) {
        guard let current = self.recording(withID: recording.id), let store else { return }
        do {
            try store.deleteFile(for: current)
            pendingRecordings.removeAll { $0.id == current.id }
            try persistPendingRecordings()
            statusMessage = "Uploaded safely; transcription is processing"
        } catch {
            errorMessage = "The upload is safe, but its device copy could not be removed."
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

    func importRecording(from sourceURL: URL, contentType: String) throws -> LocalRecording {
        guard let store else {
            throw RecordingCoordinatorError.storageUnavailable
        }
        let recording = try store.importRecording(from: sourceURL, contentType: contentType)
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
        }
    }

    func markUploadStarted(
        _ recordingID: UUID,
        objectKey: String,
        sizeBytes: Int64,
        mimeType: String,
        taskIdentifier: Int
    ) {
        updateRecording(recordingID) { recording in
            recording.state = .uploading
            recording.lastError = nil
            recording.uploadProgress = 0
            recording.uploadObjectKey = objectKey
            recording.uploadSizeBytes = sizeBytes
            recording.uploadMimeType = mimeType
            recording.uploadTaskIdentifier = taskIdentifier
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
            let newRecording = store.makeRecording(contentType: contentType)
            recording = newRecording
            pendingRecordings.insert(newRecording, at: 0)
            try persistPendingRecordings()

            let url = store.fileURL(for: newRecording)
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let replacementRecorder = try AVAudioRecorder(url: url, settings: settings)
            replacementRecorder.isMeteringEnabled = true
            guard replacementRecorder.record() else {
                throw RecordingCoordinatorError.couldNotStart
            }
            try store.protectRecordingFile(newRecording)

            audioRecorder = replacementRecorder
            activeRecordingID = newRecording.id
            isRecording = true
            isInterrupted = false
            duration = 0
            lastCheckpointedDuration = 0
            lastStorageCheckDuration = 0
            audioLevel = 0
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
            let newRecording = store.makeRecording(contentType: contentType)
            recording = newRecording
            try Data("Media Tools simulator capture".utf8).write(
                to: store.fileURL(for: newRecording),
                options: .atomic
            )
            try store.protectRecordingFile(newRecording)
            pendingRecordings.insert(newRecording, at: 0)
            try persistPendingRecordings()

            activeRecordingID = newRecording.id
            isRecording = true
            isInterrupted = false
            duration = 0
            lastCheckpointedDuration = 0
            lastStorageCheckDuration = 0
            audioLevel = 0.35
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
        if simulatesCapture {
            duration += 0.1
            audioLevel = 0.2 + (0.25 * CGFloat((sin(duration * 4) + 1) / 2))
            checkpointActiveRecordingIfNeeded()
            enforceStorageSafetyIfNeeded()
            return
        }
        guard let audioRecorder else { return }
        audioRecorder.updateMeters()
        duration = audioRecorder.currentTime
        let power = max(-60, min(0, audioRecorder.averagePower(forChannel: 0)))
        audioLevel = CGFloat(pow(10, power / 20))
        checkpointActiveRecordingIfNeeded()
        enforceStorageSafetyIfNeeded()
    }

    /// Long recordings should fail safe while there is still room to finalize
    /// their audio container and manifest. Capacity is checked infrequently so
    /// metering remains lightweight, and the saved recording stays uploadable.
    func enforceStorageSafetyIfNeeded(force: Bool = false) {
        guard isRecording,
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
        isRecording = false
        isInterrupted = false
        audioLevel = 0

        if let activeRecordingID,
           let index = pendingRecordings.firstIndex(where: { $0.id == activeRecordingID }) {
            pendingRecordings[index].duration = duration
            pendingRecordings[index].state = state
            pendingRecordings[index].lastError = state == .interrupted ? message : nil
            do {
                try persistPendingRecordings()
            } catch {
                errorMessage = "The recording was saved, but its recovery information could not be updated."
            }
        }
        self.activeRecordingID = nil
        statusMessage = message
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let finalDuration = duration
        // The saved LocalRecording retains the completed duration. `duration`
        // is the live capture clock, so carrying it into the ready state makes
        // the next recording look as though it has already been running.
        duration = 0
        if endActivityAutomatically {
            Task { [activityManager] in
                await activityManager.end(
                    recordingID: recordingIDToEnd,
                    finalDuration: finalDuration
                )
            }
        }
        return finalDuration
    }

    private func restorePendingRecordings() {
        guard let store else { return }
        do {
            pendingRecordings = try store.loadRecordings()
            var recoveredAny = false
            for index in pendingRecordings.indices where pendingRecordings[index].state == .recording {
                pendingRecordings[index].state = .interrupted
                pendingRecordings[index].lastError = "Media Tools stopped before this recording was finalized."
                recoveredAny = true
            }
            if recoveredAny {
                try persistPendingRecordings()
                statusMessage = "Recovered an interrupted recording"
                Task { [activityManager] in
                    await activityManager.end(recordingID: nil, finalDuration: 0)
                }
            }
        } catch {
            errorMessage = "Saved recordings could not be restored: \(error.localizedDescription)"
        }
    }

    private func persistPendingRecordings() throws {
        try store?.saveRecordings(pendingRecordings)
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
            if let audioRecorder {
                duration = max(duration, audioRecorder.currentTime)
            }
            checkpointActiveRecordingIfNeeded(force: true)
            timer?.invalidate()
            timer = nil
            isInterrupted = true
            audioLevel = 0
            statusMessage = "Recording paused by another audio source"
            let interruptedDuration = duration
            guard let activeRecordingID else { return }
            Task { [activityManager] in
                await activityManager.update(
                    recordingID: activeRecordingID,
                    isInterrupted: true,
                    duration: interruptedDuration
                )
            }
        case .ended:
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
                isInterrupted = false
                statusMessage = "Recording resumed"
                startMeterTimer()
                let resumedDuration = duration
                guard let activeRecordingID else { return }
                Task { [activityManager] in
                    await activityManager.update(
                        recordingID: activeRecordingID,
                        isInterrupted: false,
                        duration: resumedDuration
                    )
                }
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

    private func handleRouteChange(_ notification: Notification) {
        guard isRecording,
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

    var errorDescription: String? {
        switch self {
        case .couldNotStart:
            return "The recorder could not start."
        case .couldNotResume:
            return "The recorder could not resume."
        case .storageUnavailable:
            return "Secure recording storage is unavailable."
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
