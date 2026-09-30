import AuthenticationServices
import Foundation
import Observation
import Security
import UIKit

struct EmptyRequest: Encodable {}

struct RecoveryCodeStatus: Decodable, Equatable {
    let remaining: Int
}

struct PasskeyStatus: Decodable, Equatable {
    let count: Int
}

struct RecoveryCodeResponse: Decodable, Equatable {
    let codes: [String]
}

struct PasskeyBeginResponse<Options: Decodable>: Decodable {
    let ceremonyID: String
    let options: Options

    enum CodingKeys: String, CodingKey {
        case ceremonyID
        case ceremonyId
        case ceremonyIDSnake = "ceremony_id"
        case options
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ceremonyID = try container.decodeIfPresent(String.self, forKey: .ceremonyID)
            ?? container.decodeIfPresent(String.self, forKey: .ceremonyId)
            ?? container.decode(String.self, forKey: .ceremonyIDSnake)
        options = try container.decode(Options.self, forKey: .options)
    }
}

struct PasskeyCredentialDescriptor: Decodable, Equatable {
    let type: String
    let id: String
}

struct PasskeyAssertionOptions: Decodable, Equatable {
    let challenge: String
    let rpID: String?
    let userVerification: String?
    let allowCredentials: [PasskeyCredentialDescriptor]?

    enum CodingKeys: String, CodingKey {
        case challenge
        case rpID = "rpId"
        case userVerification
        case allowCredentials
    }
}

struct PasskeyRegistrationOptions: Decodable, Equatable {
    let challenge: String
    let rp: RelyingParty
    let user: User
    let excludeCredentials: [PasskeyCredentialDescriptor]?

    struct RelyingParty: Decodable, Equatable {
        let id: String
        let name: String?
    }

    struct User: Decodable, Equatable {
        let id: String
        let name: String
        let displayName: String?
    }
}

enum WebAuthnBase64URL {
    enum DecodeError: Error { case invalid }

    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String) throws -> Data {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))
        guard let data = Data(base64Encoded: base64) else { throw DecodeError.invalid }
        return data
    }
}

struct PasskeyAssertionCredential: Encodable, Equatable {
    let id: String
    let rawID: String
    let type = "public-key"
    let clientExtensionResults: [String: String] = [:]
    let response: Response

    struct Response: Encodable, Equatable {
        let authenticatorData: String
        let clientDataJSON: String
        let signature: String
        let userHandle: String?
    }

    enum CodingKeys: String, CodingKey {
        case id
        case rawID = "rawId"
        case type
        case clientExtensionResults
        case response
    }

    static func make(credentialID: Data,
                     clientDataJSON: Data,
                     authenticatorData: Data,
                     signature: Data,
                     userID: Data?) -> Self {
        let encodedID = WebAuthnBase64URL.encode(credentialID)
        return Self(
            id: encodedID,
            rawID: encodedID,
            response: Response(
                authenticatorData: WebAuthnBase64URL.encode(authenticatorData),
                clientDataJSON: WebAuthnBase64URL.encode(clientDataJSON),
                signature: WebAuthnBase64URL.encode(signature),
                userHandle: userID.map(WebAuthnBase64URL.encode)
            )
        )
    }
}

struct PasskeyRegistrationCredential: Encodable, Equatable {
    let id: String
    let rawID: String
    let type = "public-key"
    let clientExtensionResults: [String: String] = [:]
    let response: Response

    struct Response: Encodable, Equatable {
        let attestationObject: String
        let clientDataJSON: String
    }

    enum CodingKeys: String, CodingKey {
        case id
        case rawID = "rawId"
        case type
        case clientExtensionResults
        case response
    }

    static func make(credentialID: Data,
                     clientDataJSON: Data,
                     attestationObject: Data) -> Self {
        let encodedID = WebAuthnBase64URL.encode(credentialID)
        return Self(
            id: encodedID,
            rawID: encodedID,
            response: Response(
                attestationObject: WebAuthnBase64URL.encode(attestationObject),
                clientDataJSON: WebAuthnBase64URL.encode(clientDataJSON)
            )
        )
    }
}

enum FirstPartyAuthError: LocalizedError, Equatable {
    case canceled
    case passkeysUnavailable
    case invalidCredential
    case invalidServerOptions
    case ceremonyInProgress

    var errorDescription: String? {
        switch self {
        case .canceled:
            return "Passkey sign-in was canceled."
        case .passkeysUnavailable:
            return "Passkeys are not available on this device."
        case .invalidCredential:
            return "The passkey response could not be read."
        case .invalidServerOptions:
            return "The server sent passkey options this iPhone could not use."
        case .ceremonyInProgress:
            return "Finish the current passkey prompt before starting another."
        }
    }
}

protocol FirstPartyAuthAPI: Sendable {
    func get<T: Decodable>(_ path: String, expectedOwnerID: String?) async throws -> T
    func post<T: Decodable, B: Encodable>(_ path: String, body: B, expectedOwnerID: String?) async throws -> T
    func postPublic<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T
    func postJSON<T: Decodable>(_ path: String, bodyData: Data, authenticated: Bool) async throws -> T
}

extension APIClient: FirstPartyAuthAPI {}

private enum ActivePasskeyCeremony {
    case signIn
    case enrollment
}

@MainActor
protocol PasskeyLoginFinishJournaling: AnyObject {
    func load() throws -> PendingPasskeyLoginFinish?
    func save(_ value: PendingPasskeyLoginFinish) throws
    func delete()
}

@MainActor
protocol RecoveryCodeRedeemJournaling: AnyObject {
    func load() throws -> PendingRecoveryCodeRedeem?
    func save(_ value: PendingRecoveryCodeRedeem) throws
    func delete()
}

@MainActor
protocol RecoveryCodeRotationJournaling: AnyObject {
    func load() throws -> PendingRecoveryCodeRotation?
    func save(_ value: PendingRecoveryCodeRotation) throws
    func delete()
}

@MainActor
@Observable
final class FirstPartyAuthService {
    static let shared = FirstPartyAuthService()

    private let relyingPartyID = "media.shimizu-technology.com"
    @ObservationIgnored private let api: any FirstPartyAuthAPI
    @ObservationIgnored private let deviceSession: DeviceSessionController
    @ObservationIgnored private let passkeyLoginJournal: any PasskeyLoginFinishJournaling
    @ObservationIgnored private let recoveryRedeemJournal: any RecoveryCodeRedeemJournaling
    @ObservationIgnored private let recoveryRotationJournal: any RecoveryCodeRotationJournaling
    private var authorizationController: ASAuthorizationController?
    private var delegate: PasskeyAuthorizationDelegate?
    private var activePasskeyCeremony: ActivePasskeyCeremony?
#if DEBUG
    private(set) var authorizationRequestStartCountForTesting = 0
#endif

    init(api: any FirstPartyAuthAPI = APIClient.shared,
         deviceSession: DeviceSessionController? = nil,
         passkeyLoginJournal: (any PasskeyLoginFinishJournaling)? = nil,
         recoveryRedeemJournal: (any RecoveryCodeRedeemJournaling)? = nil,
         recoveryRotationJournal: (any RecoveryCodeRotationJournaling)? = nil) {
        self.api = api
        self.deviceSession = deviceSession ?? .shared
        self.passkeyLoginJournal = passkeyLoginJournal ?? PasskeyLoginFinishJournal.shared
        self.recoveryRedeemJournal = recoveryRedeemJournal ?? RecoveryCodeRedeemJournal.shared
        self.recoveryRotationJournal = recoveryRotationJournal ?? RecoveryCodeRotationJournal.shared
    }

    func signInWithPasskey() async throws {
        try beginPasskeyCeremony(.signIn)
        defer { endPasskeyCeremony(.signIn) }

        try await deviceSession.prepareForNewNativeSession()
        if try await retryPendingPasskeyLoginFinishIfNeeded() { return }

        let begin: PasskeyBeginResponse<PasskeyAssertionOptions> = try await api.postPublic(
            "/auth/passkeys/login/begin",
            body: EmptyRequest()
        )
        let challenge = try WebAuthnBase64URL.decode(begin.options.challenge)
        guard begin.options.rpID == nil || begin.options.rpID == relyingPartyID else {
            throw FirstPartyAuthError.invalidServerOptions
        }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingPartyID)
        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        request.userVerificationPreference = .required
        request.allowedCredentials = try Self.authorizationDescriptors(for: begin.options.allowCredentials)

        let authorization = try await perform(request: request)
        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw FirstPartyAuthError.invalidCredential
        }
        let payload = PasskeyAssertionCredential.make(
            credentialID: credential.credentialID,
            clientDataJSON: credential.rawClientDataJSON,
            authenticatorData: credential.rawAuthenticatorData,
            signature: credential.signature,
            userID: credential.userID
        )
        let pending = PendingPasskeyLoginFinish(
            ceremonyID: begin.ceremonyID,
            credentialJSONData: try Self.finishBody(
                ceremonyID: begin.ceremonyID,
                credential: payload,
                clientType: "ios",
                deviceName: Self.deviceName(),
                nextRefreshToken: try DeviceSessionController.randomRefreshToken()
            )
        )
        try passkeyLoginJournal.save(pending)
        let pair = try await finishPasskeyLogin(pending)
        try await installFirstPartySession(pair: pair, nextRefreshToken: pending.nextRefreshToken, source: .passkey)
        passkeyLoginJournal.delete()
    }

    func enrollPasskey() async throws {
        try beginPasskeyCeremony(.enrollment)
        defer { endPasskeyCeremony(.enrollment) }

        let preEnrollmentCount = try? await passkeyStatus().count
        let begin: PasskeyBeginResponse<PasskeyRegistrationOptions> = try await api.post(
            "/auth/passkeys/register/begin",
            body: EmptyRequest(),
            expectedOwnerID: nil
        )
        let challenge = try WebAuthnBase64URL.decode(begin.options.challenge)
        let userID = try WebAuthnBase64URL.decode(begin.options.user.id)
        guard begin.options.rp.id == relyingPartyID else { throw FirstPartyAuthError.invalidServerOptions }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingPartyID)
        let request = provider.createCredentialRegistrationRequest(
            challenge: challenge,
            name: begin.options.user.name,
            userID: userID
        )
        request.userVerificationPreference = .required
        request.excludedCredentials = try Self.authorizationDescriptors(for: begin.options.excludeCredentials)

        let authorization = try await perform(request: request)
        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration else {
            throw FirstPartyAuthError.invalidCredential
        }
        guard let attestationObject = credential.rawAttestationObject, !attestationObject.isEmpty else {
            throw FirstPartyAuthError.invalidCredential
        }
        let payload = PasskeyRegistrationCredential.make(
            credentialID: credential.credentialID,
            clientDataJSON: credential.rawClientDataJSON,
            attestationObject: attestationObject
        )
        do {
            let _: RegistrationFinishResponse = try await api.postJSON(
                "/auth/passkeys/register/finish",
                bodyData: try Self.finishBody(ceremonyID: begin.ceremonyID, credential: payload),
                authenticated: true
            )
        } catch {
            if let preEnrollmentCount,
               let status = try? await passkeyStatus(),
               status.count > preEnrollmentCount {
                return
            }
            throw error
        }
    }

    func passkeyStatus() async throws -> PasskeyStatus {
        try await api.get("/auth/passkeys", expectedOwnerID: nil)
    }

    func recoveryStatus() async throws -> RecoveryCodeStatus {
        try await api.get("/auth/recovery", expectedOwnerID: nil)
    }

    func beginRecoveryCodeRotation() async throws -> [String] {
        if let pending = try recoveryRotationJournal.load() { return pending.codes }
        let response: RecoveryCodeRotationBeginResponse = try await api.post(
            "/auth/recovery/rotation/begin",
            body: EmptyRequest(),
            expectedOwnerID: nil
        )
        let pending = PendingRecoveryCodeRotation(rotationID: response.rotationID, codes: response.codes)
        try recoveryRotationJournal.save(pending)
        return response.codes
    }

    func confirmRecoveryCodeRotation() async throws -> RecoveryCodeStatus {
        guard let pending = try recoveryRotationJournal.load() else { throw APIError.invalidResponse }
        do {
            let status: RecoveryCodeStatus = try await api.post(
                "/auth/recovery/rotation/confirm",
                body: RecoveryCodeRotationConfirmRequest(rotationID: pending.rotationID),
                expectedOwnerID: nil
            )
            recoveryRotationJournal.delete()
            return status
        } catch APIError.httpError(let statusCode, _, _) where statusCode == 400 || statusCode == 401 || statusCode == 404 {
            recoveryRotationJournal.delete()
            throw APIError.authenticationRequired(
                message: "These recovery codes expired or were replaced. Generate a new set. Your previous active codes are unchanged unless another device rotated them."
            )
        }
    }

    func redeemRecoveryCode(_ code: String) async throws {
        try await deviceSession.prepareForNewNativeSession()
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        var journal = try recoveryRedeemJournal.load()
        if let existing = journal, existing.code != normalizedCode {
            throw APIError.authenticationRequired(
                message: "Retry the recovery code already in progress before using a different code."
            )
        }
        if journal == nil {
            journal = PendingRecoveryCodeRedeem(
                code: normalizedCode,
                nextRefreshToken: try DeviceSessionController.randomRefreshToken()
            )
            try recoveryRedeemJournal.save(journal!)
        }
        guard let journal else { throw APIError.invalidResponse }

        do {
            let pair: DeviceSessionPair = try await api.postPublic(
                "/auth/recovery/redeem",
                body: RecoveryCodeRedeemRequest(
                    code: journal.code,
                    clientType: "ios",
                    deviceName: Self.deviceName(),
                    nextRefreshToken: journal.nextRefreshToken
                )
            )
            guard pair.refreshToken == journal.nextRefreshToken else { throw APIError.invalidResponse }
            try await installFirstPartySession(pair: pair, nextRefreshToken: journal.nextRefreshToken, source: .recoveryCode)
            recoveryRedeemJournal.delete()
        } catch APIError.httpError(let statusCode, _, _) where statusCode == 400 || statusCode == 401 || statusCode == 404 {
            recoveryRedeemJournal.delete()
            throw APIError.authenticationRequired(message: "That recovery code did not work. Check the code and try again.")
        }
    }

    private func retryPendingPasskeyLoginFinishIfNeeded() async throws -> Bool {
        guard let pending = try passkeyLoginJournal.load() else { return false }
        let pair = try await finishPasskeyLogin(pending)
        try await installFirstPartySession(pair: pair, nextRefreshToken: pending.nextRefreshToken, source: .passkey)
        passkeyLoginJournal.delete()
        return true
    }

    private func finishPasskeyLogin(_ pending: PendingPasskeyLoginFinish) async throws -> DeviceSessionPair {
        try await api.postJSON(
            "/auth/passkeys/login/finish",
            bodyData: pending.credentialJSONData,
            authenticated: false
        )
    }

    private func installFirstPartySession(pair: DeviceSessionPair,
                                          nextRefreshToken: String,
                                          source: DeviceSessionSource) async throws {
        guard pair.refreshToken == nextRefreshToken else { throw APIError.invalidResponse }
        try await deviceSession.replaceSession(pair: pair, source: source)
    }

    private func beginPasskeyCeremony(_ ceremony: ActivePasskeyCeremony) throws {
        guard activePasskeyCeremony == nil else { throw FirstPartyAuthError.ceremonyInProgress }
        activePasskeyCeremony = ceremony
    }

    private func endPasskeyCeremony(_ ceremony: ActivePasskeyCeremony) {
        guard activePasskeyCeremony == ceremony else { return }
        activePasskeyCeremony = nil
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let firstParty = error as? FirstPartyAuthError, firstParty == .canceled { return true }
        let nsError = error as NSError
        return nsError.code == ASAuthorizationError.Code.canceled.rawValue
    }

    func perform(request: ASAuthorizationRequest) async throws -> ASAuthorization {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
#if DEBUG
                authorizationRequestStartCountForTesting += 1
#endif
                let delegate = PasskeyAuthorizationDelegate { [weak self] result in
                    self?.authorizationController = nil
                    self?.delegate = nil
                    switch result {
                    case .success(let authorization):
                        continuation.resume(returning: authorization)
                    case .failure(let error):
                        if Self.isCancellation(error) {
                            continuation.resume(throwing: FirstPartyAuthError.canceled)
                        } else {
                            continuation.resume(throwing: error)
                        }
                    }
                }
                self.delegate = delegate
                let controller = ASAuthorizationController(authorizationRequests: [request])
                self.authorizationController = controller
                controller.delegate = delegate
                controller.presentationContextProvider = delegate
                controller.performRequests()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.authorizationController?.cancel()
                self?.delegate?.cancel()
                self?.authorizationController = nil
                self?.delegate = nil
            }
        }
    }


    static func authorizationDescriptors(
        for descriptors: [PasskeyCredentialDescriptor]?
    ) throws -> [ASAuthorizationPlatformPublicKeyCredentialDescriptor] {
        try (descriptors ?? []).map { descriptor in
            guard descriptor.type == "public-key" else { throw FirstPartyAuthError.invalidServerOptions }
            return ASAuthorizationPlatformPublicKeyCredentialDescriptor(
                credentialID: try WebAuthnBase64URL.decode(descriptor.id)
            )
        }
    }

    static func finishBody<Credential: Encodable>(ceremonyID: String,
                                                  credential: Credential,
                                                  clientType: String? = nil,
                                                  deviceName: String? = nil,
                                                  nextRefreshToken: String? = nil) throws -> Data {
        var body: [String: Any] = [
            "ceremony_id": ceremonyID,
            "credential": try jsonObject(for: credential),
        ]
        if let clientType { body["client_type"] = clientType }
        if let deviceName { body["device_name"] = deviceName }
        if let nextRefreshToken { body["next_refresh_token"] = nextRefreshToken }
        return try JSONSerialization.data(withJSONObject: body, options: [])
    }

    private static func jsonObject<Credential: Encodable>(for credential: Credential) throws -> Any {
        let encoder = JSONEncoder()
        let data = try encoder.encode(credential)
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func deviceName() -> String {
        let trimmed = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "iPhone" }
        return String(trimmed.prefix(80))
    }
}

private struct RegistrationFinishResponse: Decodable {
    let credentialID: String?
}

struct PendingPasskeyLoginFinish: Codable, Equatable {
    let ceremonyID: String
    let credentialJSONData: Data

    var nextRefreshToken: String {
        guard let object = try? JSONSerialization.jsonObject(with: credentialJSONData) as? [String: Any],
              let token = object["next_refresh_token"] as? String else { return "" }
        return token
    }
}

struct PendingRecoveryCodeRedeem: Codable, Equatable {
    let code: String
    let nextRefreshToken: String
}

struct PendingRecoveryCodeRotation: Codable, Equatable {
    let rotationID: String
    let codes: [String]
}

struct RecoveryCodeRedeemRequest: Encodable, Equatable {
    let code: String
    let clientType: String
    let deviceName: String
    let nextRefreshToken: String
}

struct RecoveryCodeRotationBeginResponse: Decodable, Equatable {
    let rotationID: String
    let codes: [String]

    enum CodingKeys: String, CodingKey {
        case rotationID
        case rotationId
        case rotationIDSnake = "rotation_id"
        case codes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rotationID = try container.decodeIfPresent(String.self, forKey: .rotationID)
            ?? container.decodeIfPresent(String.self, forKey: .rotationId)
            ?? container.decode(String.self, forKey: .rotationIDSnake)
        codes = try container.decode([String].self, forKey: .codes)
    }
}

struct RecoveryCodeRotationConfirmRequest: Encodable, Equatable {
    let rotationID: String

    enum CodingKeys: String, CodingKey {
        case rotationID = "rotation_id"
    }
}

@MainActor
final class PasskeyLoginFinishJournal: PasskeyLoginFinishJournaling {
    static let shared = PasskeyLoginFinishJournal()

    private let service = "com.shimizu-technology.media-tools.passkey-login-finish"
    private let account = "passkey-login-finish-v1"

    func load() throws -> PendingPasskeyLoginFinish? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw RecoveryJournalKeychainFailure(status: status)
        }
        return try JSONDecoder().decode(PendingPasskeyLoginFinish.self, from: data)
    }

    func save(_ value: PendingPasskeyLoginFinish) throws {
        let data = try JSONEncoder().encode(value)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw RecoveryJournalKeychainFailure(status: status) }
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw RecoveryJournalKeychainFailure(status: addStatus) }
    }

    func delete() { SecItemDelete(baseQuery as CFDictionary) }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

@MainActor
final class RecoveryCodeRotationJournal: RecoveryCodeRotationJournaling {
    static let shared = RecoveryCodeRotationJournal()

    private let service = "com.shimizu-technology.media-tools.recovery-rotation"
    private let account = "recovery-code-rotation-v1"

    func load() throws -> PendingRecoveryCodeRotation? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw RecoveryJournalKeychainFailure(status: status)
        }
        return try JSONDecoder().decode(PendingRecoveryCodeRotation.self, from: data)
    }

    func save(_ value: PendingRecoveryCodeRotation) throws {
        let data = try JSONEncoder().encode(value)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw RecoveryJournalKeychainFailure(status: status) }
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw RecoveryJournalKeychainFailure(status: addStatus) }
    }

    func delete() { SecItemDelete(baseQuery as CFDictionary) }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

@MainActor
final class RecoveryCodeRedeemJournal: RecoveryCodeRedeemJournaling {
    static let shared = RecoveryCodeRedeemJournal()

    private let service = "com.shimizu-technology.media-tools.recovery-redeem"
    private let account = "recovery-code-redeem-v1"

    func load() throws -> PendingRecoveryCodeRedeem? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw RecoveryJournalKeychainFailure(status: status)
        }
        return try JSONDecoder().decode(PendingRecoveryCodeRedeem.self, from: data)
    }

    func save(_ value: PendingRecoveryCodeRedeem) throws {
        let data = try JSONEncoder().encode(value)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw RecoveryJournalKeychainFailure(status: status) }
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw RecoveryJournalKeychainFailure(status: addStatus) }
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

private struct RecoveryJournalKeychainFailure: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Could not save this recovery sign-in (\(status))." }
}

final class PasskeyAuthorizationDelegate: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let completion: (Result<ASAuthorization, Error>) -> Void
    private var didComplete = false

    init(completion: @escaping (Result<ASAuthorization, Error>) -> Void) {
        self.completion = completion
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        complete(.success(authorization))
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        complete(.failure(error))
    }

    func cancel() {
        complete(.failure(FirstPartyAuthError.canceled))
    }

    private func complete(_ result: Result<ASAuthorization, Error>) {
        guard !didComplete else { return }
        didComplete = true
        completion(result)
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
