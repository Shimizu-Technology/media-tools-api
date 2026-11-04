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

struct PasswordStatus: Decodable, Equatable {
    let configured: Bool
    let updatedAt: Date?
}

struct EmailAuthReceipt: Decodable, Equatable {
    let message: String
}

struct EmailProofResult: Decodable, Equatable {
    let verified: Bool
    let signInRequired: Bool
}

struct AccountProfile: Decodable, Equatable {
    let id: String
    let email: String
    let name: String
    var clerkId: String? = nil
    var emailVerified: Bool? = nil
}

struct AccountUsage: Decodable, Equatable {
    let month: Date
    let transcriptionSeconds: Int
    let transcriptionLimitSeconds: Int
    let aiRequests: Int
    let aiRequestLimit: Int
    let exempt: Bool
}

struct DeviceSessionSummary: Decodable, Equatable, Identifiable {
    let id: String
    let clientType: String
    let deviceName: String?
    let createdAt: Date
    let lastUsedAt: Date?
    let inactiveExpiresAt: Date
    let revokedAt: Date?

    var isUsable: Bool {
        revokedAt == nil && inactiveExpiresAt > Date()
    }
}

struct DeviceSessionListResponse: Decodable, Equatable {
    let sessions: [DeviceSessionSummary]
}

struct RecoveryCodeResponse: Decodable, Equatable {
    let codes: [String]
}

/// Wire shape decoded by APIClient's snake-case strategy. DeviceSessionPair
/// keeps explicit snake-case keys for Keychain compatibility, so API responses
/// must cross this DTO before becoming a stored pair.
struct DeviceSessionPairResponse: Decodable, Equatable {
    let sessionId: String
    let userId: String
    let accessToken: String
    let accessExpiresAt: Date
    let refreshToken: String
    let inactiveExpiresAt: Date

    var pair: DeviceSessionPair {
        DeviceSessionPair(
            sessionID: sessionId,
            userID: userId,
            accessToken: accessToken,
            accessExpiresAt: accessExpiresAt,
            refreshToken: refreshToken,
            inactiveExpiresAt: inactiveExpiresAt
        )
    }
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
    /// The code and new password were accepted. Only the sign-in afterward failed,
    /// so the person should sign in rather than repeat a used code.
    case signInNeededAfterProof

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
        case .signInNeededAfterProof:
            return "Your password is saved. Sign in to continue."
        }
    }
}

protocol FirstPartyAuthAPI: Sendable {
    func delete(_ path: String) async throws
    func get<T: Decodable>(_ path: String, expectedOwnerID: String?) async throws -> T
    func post<T: Decodable, B: Encodable>(_ path: String, body: B, expectedOwnerID: String?) async throws -> T
    func postPublic<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T
    func postJSON<T: Decodable>(_ path: String, bodyData: Data, authenticated: Bool) async throws -> T
}

extension APIClient: FirstPartyAuthAPI {}

/// What a person reads when an auth request fails. Nothing here may say whether an
/// account exists; the sign-in and email responses are generic for that reason.
enum AuthCopy {
    /// Also what the server returns. Shown for every address, known or not.
    static let emailReceipt = "If this request is eligible, an email will arrive shortly"
    /// The server stops checking passwords after repeated failures and allows one
    /// check every 30 seconds, answering the rest as incorrect, even a correct one.
    static let incorrectPassword =
        "Email or password is incorrect. After several tries, wait 30 seconds between attempts, even with the right password."
    static let tooManySignInAttempts =
        "Too many unsuccessful attempts. Wait 30 seconds, then try your correct password, or use Forgot password."

    static func message(for error: Error, fallback: String) -> String {
        switch error {
        case let error as FirstPartyAuthError:
            return error.errorDescription ?? fallback
        case let error as URLError where error.code != .cancelled:
            return "Could not reach Media Tools. Check your connection and try again."
        case APIError.authenticationRequired(let message),
             APIError.authenticationTemporarilyUnavailable(let message):
            return message
        case APIError.rateLimited(let retryAfter, _):
            return rateLimitMessage(retryAfter: retryAfter)
        case APIError.httpError(_, let code, let message):
            return copy(forCode: code) ?? (message.isEmpty ? fallback : message)
        default:
            return fallback
        }
    }

    private static func copy(forCode code: String?) -> String? {
        switch code {
        case "weak_password":
            return "Use a password of 12 to 128 characters."
        case "password_compromised":
            return "That password has appeared in a data breach. Choose a different one."
        case "invalid_code":
            return "That code did not work. It may have expired or already been used. Send a new code and try again."
        case "invalid_credentials":
            return incorrectPassword
        case "current_password_required":
            return "Your current password is incorrect."
        case "email_verification_required":
            return "Verify your email before setting a password."
        case "signup_disabled":
            return "Sign-up is not available right now."
        case "password_required":
            return "Set a password before changing your email."
        case "credential_changed":
            return "Your password changed on another device. Sign in again."
        case "authentication_unavailable", "usage_unavailable":
            return "Media Tools could not finish this right now. Try again shortly."
        default:
            return nil
        }
    }

    private static func rateLimitMessage(retryAfter: TimeInterval?) -> String {
        guard let retryAfter, retryAfter > 0 else {
            return "Too many attempts. Wait a little while and try again."
        }
        let minutes = Int((retryAfter / 60).rounded(.up))
        if minutes <= 1 {
            return "Too many attempts. Try again in a minute."
        }
        return "Too many attempts. Try again in \(minutes) minutes."
    }
}

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
protocol PasswordLoginJournaling: AnyObject {
    func load() throws -> PendingPasswordLogin?
    func save(_ value: PendingPasswordLogin) throws
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
    @ObservationIgnored private let passwordLoginJournal: any PasswordLoginJournaling
    private var authorizationController: ASAuthorizationController?
    private var delegate: PasskeyAuthorizationDelegate?
    private var activePasskeyCeremony: ActivePasskeyCeremony?
    /// Proof requests whose last attempt ended with no answer from the server.
    private var unconfirmedProofPaths: Set<String> = []
#if DEBUG
    private(set) var authorizationRequestStartCountForTesting = 0
#endif

    init(api: any FirstPartyAuthAPI = APIClient.shared,
         deviceSession: DeviceSessionController? = nil,
         passkeyLoginJournal: (any PasskeyLoginFinishJournaling)? = nil,
         recoveryRedeemJournal: (any RecoveryCodeRedeemJournaling)? = nil,
         recoveryRotationJournal: (any RecoveryCodeRotationJournaling)? = nil,
         passwordLoginJournal: (any PasswordLoginJournaling)? = nil) {
        self.api = api
        self.deviceSession = deviceSession ?? .shared
        self.passkeyLoginJournal = passkeyLoginJournal ?? PasskeyLoginFinishJournal.shared
        self.recoveryRedeemJournal = recoveryRedeemJournal ?? RecoveryCodeRedeemJournal.shared
        self.recoveryRotationJournal = recoveryRotationJournal ?? RecoveryCodeRotationJournal.shared
        self.passwordLoginJournal = passwordLoginJournal ?? PasswordLoginJournal.shared
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
        try await completeSavedPasskeyLogin(pending)
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

    func passwordStatus() async throws -> PasswordStatus {
        try await api.get("/auth/password", expectedOwnerID: nil)
    }

    /// `currentPassword` is required once a password exists. The first password on
    /// an account takes none, but its email must have been proved first.
    func setPassword(_ password: String, currentPassword: String? = nil) async throws -> PasswordStatus {
        try await api.post(
            "/auth/password",
            body: SetPasswordRequest(password: password, currentPassword: currentPassword),
            expectedOwnerID: activeRecoveryOwnerID()
        )
    }

    func accountProfile() async throws -> AccountProfile {
        try await api.get("/auth/me", expectedOwnerID: nil)
    }

    func usage() async throws -> AccountUsage {
        try await api.get("/auth/usage", expectedOwnerID: nil)
    }

    func deviceSessions() async throws -> [DeviceSessionSummary] {
        let response: DeviceSessionListResponse = try await api.get("/auth/sessions", expectedOwnerID: nil)
        return response.sessions
    }

    func revokeDeviceSession(id: String) async throws {
        try await api.delete("/auth/sessions/\(id)")
    }

    // MARK: - Email proof

    /// The response is the same for any address, so the caller shows a fixed receipt.
    func beginSignUp(email: String, name: String?) async throws {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let _: EmailAuthReceipt = try await api.postPublic(
            "/auth/signup",
            body: SignUpRequest(
                email: Self.normalized(email),
                name: trimmedName?.isEmpty == false ? trimmedName : nil
            )
        )
    }

    func finishSignUp(email: String, code: String, password: String) async throws {
        try await finishSignedOutProof(
            "/auth/signup/verify",
            email: Self.normalized(email),
            code: code,
            password: password
        )
    }

    func beginPasswordReset(email: String) async throws {
        let _: EmailAuthReceipt = try await api.postPublic(
            "/auth/password/forgot",
            body: EmailOnlyRequest(email: Self.normalized(email))
        )
    }

    func finishPasswordReset(email: String, code: String, password: String) async throws {
        try await finishSignedOutProof(
            "/auth/password/reset",
            email: Self.normalized(email),
            code: code,
            password: password
        )
    }

    /// A proof response can be lost after the server committed it, and repeating
    /// the code then gets `invalid_code`. The new password is what tells them apart.
    private func finishSignedOutProof(_ path: String, email: String, code: String, password: String) async throws {
        do {
            let _: EmailProofResult = try await api.postPublic(
                path,
                body: EmailProofRequest(email: email, code: code, password: password)
            )
            unconfirmedProofPaths.remove(path)
        } catch {
            if Self.isConnectionFailure(error) {
                unconfirmedProofPaths.insert(path)
                throw error
            }
            guard Self.isInvalidCode(error), unconfirmedProofPaths.remove(path) != nil else { throw error }
            do {
                try await signInWithPassword(email: email, password: password)
                return
            } catch {
                throw APIError.httpError(statusCode: 400, code: "invalid_code", message: "")
            }
        }
        try await signInAfterProof(email: email, password: password)
    }

    private func signInAfterProof(email: String, password: String) async throws {
        do {
            try await signInWithPassword(email: email, password: password)
        } catch {
            throw FirstPartyAuthError.signInNeededAfterProof
        }
    }

    func beginEmailVerification(email: String) async throws {
        let _: EmailAuthReceipt = try await api.post(
            "/auth/email/verify",
            body: EmailOnlyRequest(email: Self.normalized(email)),
            expectedOwnerID: activeRecoveryOwnerID()
        )
    }

    func confirmEmailVerification(email: String, code: String) async throws {
        let _: EmailProofResult = try await api.post(
            "/auth/email/verify/confirm",
            body: EmailCodeRequest(email: Self.normalized(email), code: code),
            expectedOwnerID: activeRecoveryOwnerID()
        )
    }

    func beginEmailChange(newEmail: String, currentPassword: String) async throws {
        let _: EmailAuthReceipt = try await api.post(
            "/auth/email/change",
            body: EmailChangeRequest(email: Self.normalized(newEmail), currentPassword: currentPassword),
            expectedOwnerID: activeRecoveryOwnerID()
        )
    }

    /// Changing email revokes every session and key on the account, including this
    /// one. Signing straight back in keeps the person where they were, and the same
    /// account ID means their recordings never change hands.
    func finishEmailChange(newEmail: String, code: String, currentPassword: String) async throws {
        let email = Self.normalized(newEmail)
        let path = "/auth/email/change/verify"
        do {
            let _: EmailProofResult = try await api.post(
                path,
                body: EmailCodeRequest(email: email, code: code),
                expectedOwnerID: activeRecoveryOwnerID()
            )
            unconfirmedProofPaths.remove(path)
        } catch {
            if Self.isConnectionFailure(error) {
                unconfirmedProofPaths.insert(path)
                throw error
            }
            // A lost success already revoked this session, so the retry comes back
            // as a rejected credential rather than a used code.
            guard Self.isInvalidCode(error) || Self.isAuthenticationFailure(error),
                  unconfirmedProofPaths.remove(path) != nil else { throw error }
        }
        try await signInAfterProof(email: email, password: currentPassword)
    }

    private static func normalized(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isConnectionFailure(_ error: Error) -> Bool {
        error is URLError
    }

    private static func isInvalidCode(_ error: Error) -> Bool {
        if case APIError.httpError(_, "invalid_code", _) = error { return true }
        return false
    }

    private static func isAuthenticationFailure(_ error: Error) -> Bool {
        RecordingUploadCoordinator.isAuthenticationFailure(error)
    }

    func signInWithPassword(email: String, password: String) async throws {
        try await deviceSession.prepareForNewNativeSession()
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var pending = try passwordLoginJournal.load()
        if let existing = pending, existing.email != normalizedEmail {
            passwordLoginJournal.delete()
            pending = nil
        }
        if pending == nil {
            pending = PendingPasswordLogin(
                email: normalizedEmail,
                nextRefreshToken: try DeviceSessionController.randomRefreshToken()
            )
            try passwordLoginJournal.save(pending!)
        }
        guard let pending else { throw APIError.invalidResponse }
        do {
            let response: DeviceSessionPairResponse = try await api.postPublic(
                "/auth/password/login",
                body: PasswordLoginRequest(
                    email: pending.email,
                    password: password,
                    clientType: "ios",
                    deviceName: Self.deviceName(),
                    nextRefreshToken: pending.nextRefreshToken
                )
            )
            let pair = response.pair
            guard pair.refreshToken == pending.nextRefreshToken else { throw APIError.invalidResponse }
            // Builds 12 and 13 understand .passkey and .recoveryCode only. Reusing
            // .passkey keeps a downgraded app from discarding this session.
            try await installFirstPartySession(pair: pair, nextRefreshToken: pending.nextRefreshToken, source: .passkey)
            passwordLoginJournal.delete()
        } catch APIError.httpError(let statusCode, let code, _) where statusCode == 400 || statusCode == 401 {
            if statusCode == 400 { passwordLoginJournal.delete() }
            throw APIError.authenticationRequired(
                message: code == "invalid_credentials"
                    ? AuthCopy.incorrectPassword
                    : "Could not use that saved sign-in. Try again."
            )
        } catch APIError.rateLimited {
            // Retry-After here is the failure window, not a lockout. A correct
            // password still gets through 30 seconds after the last attempt.
            throw APIError.authenticationRequired(message: AuthCopy.tooManySignInAttempts)
        }
    }

    func beginRecoveryCodeRotation() async throws -> [String] {
        let ownerID = try activeRecoveryOwnerID()
        if let pending = try recoveryRotationJournal.load() {
            guard pending.userID == ownerID else {
                recoveryRotationJournal.delete()
                throw APIError.authenticationRequired(
                    message: "The signed-in account changed. Create recovery codes for this account."
                )
            }
            return pending.codes
        }
        let response: RecoveryCodeRotationBeginResponse = try await api.post(
            "/auth/recovery/rotation/begin",
            body: EmptyRequest(),
            expectedOwnerID: ownerID
        )
        let pending = PendingRecoveryCodeRotation(
            userID: ownerID,
            rotationID: response.rotationID,
            codes: response.codes
        )
        try recoveryRotationJournal.save(pending)
        return response.codes
    }

    func confirmRecoveryCodeRotation() async throws -> RecoveryCodeStatus {
        let ownerID = try activeRecoveryOwnerID()
        guard let pending = try recoveryRotationJournal.load() else { throw APIError.invalidResponse }
        guard pending.userID == ownerID else {
            recoveryRotationJournal.delete()
            throw APIError.authenticationRequired(
                message: "The signed-in account changed. Create recovery codes for this account."
            )
        }
        do {
            let status: RecoveryCodeStatus = try await api.post(
                "/auth/recovery/rotation/confirm",
                body: RecoveryCodeRotationConfirmRequest(rotationID: pending.rotationID),
                expectedOwnerID: ownerID
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
            let response: DeviceSessionPairResponse = try await api.postPublic(
                "/auth/recovery/redeem",
                body: RecoveryCodeRedeemRequest(
                    code: journal.code,
                    clientType: "ios",
                    deviceName: Self.deviceName(),
                    nextRefreshToken: journal.nextRefreshToken
                )
            )
            let pair = response.pair
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
        try await completeSavedPasskeyLogin(pending)
        return true
    }

    // Both a newly completed platform ceremony and a relaunch retry enter here
    // after their exact finish body has been saved. Keeping one completion path
    // ensures neither route can strand a permanently rejected ceremony.
    func completeSavedPasskeyLogin(_ pending: PendingPasskeyLoginFinish) async throws {
        do {
            let pair = try await finishPasskeyLogin(pending)
            try await installFirstPartySession(
                pair: pair,
                nextRefreshToken: pending.nextRefreshToken,
                source: .passkey
            )
            passkeyLoginJournal.delete()
        } catch APIError.httpError(let statusCode, _, _)
            where statusCode == 400 || statusCode == 401 || statusCode == 404 {
            // The ceremony can no longer be recovered. Remove the journal so
            // the next tap starts a fresh platform passkey ceremony instead of
            // retrying the same expired response forever.
            passkeyLoginJournal.delete()
            throw APIError.authenticationRequired(
                message: "That passkey sign-in expired. Please try again."
            )
        }
    }

    private func finishPasskeyLogin(_ pending: PendingPasskeyLoginFinish) async throws -> DeviceSessionPair {
        let response: DeviceSessionPairResponse = try await api.postJSON(
            "/auth/passkeys/login/finish",
            bodyData: pending.credentialJSONData,
            authenticated: false
        )
        return response.pair
    }

    func clearSessionScopedJournals() {
        recoveryRotationJournal.delete()
    }

    private func activeRecoveryOwnerID() throws -> String {
        guard let ownerID = deviceSession.activeUserID, !ownerID.isEmpty else {
            throw APIError.authenticationRequired(message: "Sign in to manage recovery codes.")
        }
        return ownerID
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
        return nsError.domain == ASAuthorizationError.errorDomain
            && nsError.code == ASAuthorizationError.Code.canceled.rawValue
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
    let userID: String
    let rotationID: String
    let codes: [String]
}

struct PendingPasswordLogin: Codable, Equatable {
    let email: String
    let nextRefreshToken: String
}

struct PasswordLoginRequest: Encodable, Equatable {
    let email: String
    let password: String
    let clientType: String
    let deviceName: String
    let nextRefreshToken: String
}

struct SetPasswordRequest: Encodable, Equatable {
    let password: String
    var currentPassword: String? = nil
}

struct SignUpRequest: Encodable, Equatable {
    let email: String
    let name: String?
}

struct EmailOnlyRequest: Encodable, Equatable {
    let email: String
}

struct EmailProofRequest: Encodable, Equatable {
    let email: String
    let code: String
    let password: String
}

struct EmailCodeRequest: Encodable, Equatable {
    let email: String
    let code: String
}

struct EmailChangeRequest: Encodable, Equatable {
    let email: String
    let currentPassword: String
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
        do {
            return try JSONDecoder().decode(PendingPasskeyLoginFinish.self, from: data)
        } catch {
            // A partially written or legacy journal cannot be replayed safely.
            // Remove only this passkey-finish item so a fresh ceremony can begin.
            delete()
            return nil
        }
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
        do {
            return try JSONDecoder().decode(PendingRecoveryCodeRotation.self, from: data)
        } catch {
            // Ownerless legacy or corrupt state must never cross accounts.
            delete()
            return nil
        }
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
    var errorDescription: String? {
        "Media Tools couldn’t secure this sign-in. Restart the app and try again."
    }
}

@MainActor
final class PasswordLoginJournal: PasswordLoginJournaling {
    static let shared = PasswordLoginJournal()
    private let service = "com.shimizu-technology.media-tools.password-login"
    private let account = "password-login-v1"

    func load() throws -> PendingPasswordLogin? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw RecoveryJournalKeychainFailure(status: status)
        }
        do { return try JSONDecoder().decode(PendingPasswordLogin.self, from: data) }
        catch { delete(); return nil }
    }

    func save(_ value: PendingPasswordLogin) throws {
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
