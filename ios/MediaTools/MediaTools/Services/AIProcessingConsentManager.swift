import Foundation
import Observation

/// The "Automatically transcribe" setting. It is on unless an account turned it
/// off, and a signed-out capture follows the default until an account claims it.
/// This stays separate from the consent manager so `RecordingCoordinator` can
/// read it while saving a recording without depending on the consent UI.
struct AutoTranscribePreference {
    static let disabledOwnersKey = "autoTranscribeDisabledOwnerIDs.v1"

    let defaults: UserDefaults

    func isEnabled(ownerID: String?) -> Bool {
        guard let ownerID else { return true }
        return !disabledOwnerIDs.contains(ownerID)
    }

    func setEnabled(_ enabled: Bool, ownerID: String) {
        var owners = disabledOwnerIDs
        if enabled {
            owners.remove(ownerID)
        } else {
            owners.insert(ownerID)
        }
        persist(owners)
    }

    func migrate(from previousOwnerID: String, to ownerID: String) {
        var owners = disabledOwnerIDs
        guard owners.remove(previousOwnerID) != nil else { return }
        owners.insert(ownerID)
        persist(owners)
    }

    func remove(ownerID: String) {
        var owners = disabledOwnerIDs
        guard owners.remove(ownerID) != nil else { return }
        persist(owners)
    }

    private var disabledOwnerIDs: Set<String> {
        Set(defaults.stringArray(forKey: Self.disabledOwnersKey) ?? [])
    }

    private func persist(_ owners: Set<String>) {
        if owners.isEmpty {
            defaults.removeObject(forKey: Self.disabledOwnersKey)
        } else {
            defaults.set(owners.sorted(), forKey: Self.disabledOwnersKey)
        }
    }
}

/// Owns explicit, account-scoped permission for sharing content with third-party AI.
/// The permission is intentionally device-local: each installation asks the person
/// using it before that device sends recordings, text, or prompts to an AI provider.
@MainActor
@Observable
final class AIProcessingConsentManager {
    static let shared = AIProcessingConsentManager(
        sharePolicy: try? ShareUploadPolicyFileStore()
    )

    private static let consentedOwnersKey = "aiProcessingConsentedOwnerIDs.v1"
    /// Accounts that saw the disclosure saying new recordings are sent when they
    /// are saved. The v1 grant above was given under copy promising audio is sent
    /// only on request, so it still covers manual actions but not automatic ones.
    private static let automaticOwnersKey = "aiAutomaticTranscriptionOwnerIDs.v1"
    private static let promptedOwnersKey = "aiAutomaticTranscriptionPromptedOwnerIDs.v1"

    private let defaults: UserDefaults
    private let autoTranscribePreference: AutoTranscribePreference
    private let sharePolicy: (any ShareUploadPolicyStoring)?
    private let apiBaseURL: String
    private var pendingContinuations: [CheckedContinuation<Bool, Never>] = []

    private(set) var activeOwnerID: String?
    private(set) var isPresentingDisclosure = false
    /// UserDefaults changes are invisible to Observation; this makes the views
    /// that read them update when a grant or the setting changes.
    private var stateRevision = 0
    /// Lets the upload coordinator react without the views knowing about it.
    var onAutomaticTranscriptionStateChanged: (() -> Void)?

    init(
        defaults: UserDefaults = .standard,
        sharePolicy: (any ShareUploadPolicyStoring)? = nil,
        apiBaseURL: String = Configuration.apiBaseURL
    ) {
        self.defaults = defaults
        autoTranscribePreference = AutoTranscribePreference(defaults: defaults)
        self.sharePolicy = sharePolicy
        self.apiBaseURL = apiBaseURL
    }

    var hasConsent: Bool {
        guard let activeOwnerID else { return false }
        return hasConsent(ownerID: activeOwnerID)
    }

    func hasConsent(ownerID: String) -> Bool {
        _ = stateRevision
        return consentedOwnerIDs.contains(ownerID)
    }

    var hasAutomaticConsent: Bool {
        guard let activeOwnerID else { return false }
        return hasAutomaticConsent(ownerID: activeOwnerID)
    }

    func hasAutomaticConsent(ownerID: String) -> Bool {
        _ = stateRevision
        return ownerIDs(forKey: Self.automaticOwnersKey).contains(ownerID)
    }

    var isAutoTranscribeEnabled: Bool {
        isAutoTranscribeEnabled(ownerID: activeOwnerID)
    }

    func isAutoTranscribeEnabled(ownerID: String?) -> Bool {
        _ = stateRevision
        return autoTranscribePreference.isEnabled(ownerID: ownerID)
    }

    func setAutoTranscribeEnabled(_ enabled: Bool) {
        guard let activeOwnerID else { return }
        autoTranscribePreference.setEnabled(enabled, ownerID: activeOwnerID)
        didChangeAutomaticTranscriptionState()
    }

    /// Asks at most once per account, so declining is respected and a saved
    /// recording never nags. A manual Transcribe tap can still ask again.
    @discardableResult
    func promptOnceForAutomaticTranscription() -> Bool {
        guard let activeOwnerID,
              !hasAutomaticConsent(ownerID: activeOwnerID),
              !isPresentingDisclosure,
              !ownerIDs(forKey: Self.promptedOwnersKey).contains(activeOwnerID)
        else { return false }
        insert(activeOwnerID, forKey: Self.promptedOwnersKey)
        isPresentingDisclosure = true
        return true
    }

    /// Settings' path for an account that declined the automatic prompt, or
    /// whose earlier grant predates automatic transcription.
    func requestAutomaticPermission() async -> Bool {
        guard activeOwnerID != nil else { return false }
        if hasAutomaticConsent { return true }

        isPresentingDisclosure = true
        return await withCheckedContinuation { continuation in
            pendingContinuations.append(continuation)
        }
    }

    func setActiveOwnerID(_ ownerID: String?) {
        guard activeOwnerID != ownerID else { return }
        decline()
        activeOwnerID = ownerID
        publishSharePolicy()
    }

    /// The extension can only read what is published here. Each change republishes
    /// its answer, and an unknown owner or a failed write leaves no permission at
    /// all, so a share falls back to waiting for the app.
    private func publishSharePolicy() {
        guard let sharePolicy else { return }
        guard let activeOwnerID else {
            sharePolicy.clear()
            return
        }
        do {
            try sharePolicy.save(ShareUploadPolicy(
                ownerID: activeOwnerID,
                mayUploadAutomatically: hasAutomaticConsent(ownerID: activeOwnerID)
                    && autoTranscribePreference.isEnabled(ownerID: activeOwnerID),
                apiBaseURL: apiBaseURL
            ))
        } catch {
            sharePolicy.clear()
        }
    }

    func requestPermission() async -> Bool {
        guard activeOwnerID != nil else { return false }
        if hasConsent { return true }

        isPresentingDisclosure = true
        return await withCheckedContinuation { continuation in
            pendingContinuations.append(continuation)
        }
    }

    func allow() {
        guard let activeOwnerID else {
            settlePending(with: false)
            return
        }
        insert(activeOwnerID, forKey: Self.consentedOwnersKey)
        insert(activeOwnerID, forKey: Self.automaticOwnersKey)
        settlePending(with: true)
        didChangeAutomaticTranscriptionState()
    }

    func decline() {
        settlePending(with: false)
    }

    func revoke() {
        guard let activeOwnerID else { return }
        // First, so a crash partway through can only leave too little permission.
        sharePolicy?.clear()
        remove(activeOwnerID, forKey: Self.consentedOwnersKey)
        remove(activeOwnerID, forKey: Self.automaticOwnersKey)
        // Revoking is the answer. The next saved recording must not ask again.
        insert(activeOwnerID, forKey: Self.promptedOwnersKey)
        didChangeAutomaticTranscriptionState()
    }

    func removeConsent(ownerID: String) {
        remove(ownerID, forKey: Self.consentedOwnersKey)
        remove(ownerID, forKey: Self.automaticOwnersKey)
        remove(ownerID, forKey: Self.promptedOwnersKey)
        autoTranscribePreference.remove(ownerID: ownerID)
        didChangeAutomaticTranscriptionState()
    }

    /// Only call with a provider ID the server verified for this exact user.
    /// Move the grant so a later activation cannot restore revoked permission.
    func migrateConsent(from clerkID: String, to userID: String) {
        guard clerkID != userID else { return }
        for key in [Self.consentedOwnersKey, Self.automaticOwnersKey, Self.promptedOwnersKey]
        where ownerIDs(forKey: key).contains(clerkID) {
            remove(clerkID, forKey: key)
            insert(userID, forKey: key)
        }
        autoTranscribePreference.migrate(from: clerkID, to: userID)
        didChangeAutomaticTranscriptionState()
    }

    private var consentedOwnerIDs: Set<String> {
        ownerIDs(forKey: Self.consentedOwnersKey)
    }

    private func ownerIDs(forKey key: String) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    private func insert(_ ownerID: String, forKey key: String) {
        var owners = ownerIDs(forKey: key)
        owners.insert(ownerID)
        defaults.set(owners.sorted(), forKey: key)
    }

    private func remove(_ ownerID: String, forKey key: String) {
        var owners = ownerIDs(forKey: key)
        owners.remove(ownerID)
        if owners.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(owners.sorted(), forKey: key)
        }
    }

    private func didChangeAutomaticTranscriptionState() {
        stateRevision += 1
        publishSharePolicy()
        onAutomaticTranscriptionStateChanged?()
    }

    #if DEBUG
    /// Deterministic fixtures for UI tests. Release builds do not contain this.
    func resetForUITesting() {
        for key in [
            Self.consentedOwnersKey, Self.automaticOwnersKey, Self.promptedOwnersKey,
            AutoTranscribePreference.disabledOwnersKey,
        ] {
            defaults.removeObject(forKey: key)
        }
    }

    func grantForUITesting(ownerID: String) {
        insert(ownerID, forKey: Self.consentedOwnersKey)
        insert(ownerID, forKey: Self.automaticOwnersKey)
    }
    #endif

    private func settlePending(with result: Bool) {
        isPresentingDisclosure = false
        let continuations = pendingContinuations
        pendingContinuations.removeAll()
        continuations.forEach { $0.resume(returning: result) }
    }
}
