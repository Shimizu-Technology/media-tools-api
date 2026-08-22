import Foundation
import Observation

/// Owns explicit, account-scoped permission for sharing content with third-party AI.
/// The permission is intentionally device-local: each installation asks the person
/// using it before that device sends recordings, text, or prompts to an AI provider.
@MainActor
@Observable
final class AIProcessingConsentManager {
    static let shared = AIProcessingConsentManager()

    private static let consentedOwnersKey = "aiProcessingConsentedOwnerIDs.v1"

    private let defaults: UserDefaults
    private var pendingContinuations: [CheckedContinuation<Bool, Never>] = []

    private(set) var activeOwnerID: String?
    private(set) var isPresentingDisclosure = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasConsent: Bool {
        guard let activeOwnerID else { return false }
        return consentedOwnerIDs.contains(activeOwnerID)
    }

    func setActiveOwnerID(_ ownerID: String?) {
        guard activeOwnerID != ownerID else { return }
        decline()
        activeOwnerID = ownerID
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
        var owners = consentedOwnerIDs
        owners.insert(activeOwnerID)
        defaults.set(owners.sorted(), forKey: Self.consentedOwnersKey)
        settlePending(with: true)
    }

    func decline() {
        settlePending(with: false)
    }

    func revoke() {
        guard let activeOwnerID else { return }
        var owners = consentedOwnerIDs
        owners.remove(activeOwnerID)
        if owners.isEmpty {
            defaults.removeObject(forKey: Self.consentedOwnersKey)
        } else {
            defaults.set(owners.sorted(), forKey: Self.consentedOwnersKey)
        }
    }

    func removeConsent(ownerID: String) {
        var owners = consentedOwnerIDs
        owners.remove(ownerID)
        if owners.isEmpty {
            defaults.removeObject(forKey: Self.consentedOwnersKey)
        } else {
            defaults.set(owners.sorted(), forKey: Self.consentedOwnersKey)
        }
    }

    private var consentedOwnerIDs: Set<String> {
        Set(defaults.stringArray(forKey: Self.consentedOwnersKey) ?? [])
    }

    private func settlePending(with result: Bool) {
        isPresentingDisclosure = false
        let continuations = pendingContinuations
        pendingContinuations.removeAll()
        continuations.forEach { $0.resume(returning: result) }
    }
}
