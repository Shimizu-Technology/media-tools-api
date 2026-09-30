import AuthenticationServices
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import MediaTools

final class FirstPartyAuthServiceTests: XCTestCase {
    func testBase64URLEncodingRemovesPaddingAndRoundTrips() throws {
        let data = Data([0xfb, 0xff, 0x10, 0x00])
        let encoded = WebAuthnBase64URL.encode(data)
        XCTAssertEqual(encoded, "-_8QAA")
        XCTAssertFalse(encoded.contains("="))
        XCTAssertEqual(try WebAuthnBase64URL.decode(encoded), data)
    }

    func testBase64URLRejectsInvalidInput() {
        XCTAssertThrowsError(try WebAuthnBase64URL.decode("not valid ***"))
    }

    func testAssertionCredentialUsesWebAuthnJSONKeys() throws {
        let credential = PasskeyAssertionCredential.make(
            credentialID: Data([1, 2, 3]),
            clientDataJSON: Data("client".utf8),
            authenticatorData: Data("auth".utf8),
            signature: Data("sig".utf8),
            userID: Data("user".utf8)
        )
        let object = try jsonObject(for: credential)
        XCTAssertEqual(object["id"] as? String, "AQID")
        XCTAssertEqual(object["rawId"] as? String, "AQID")
        XCTAssertNil(object["raw_id"])
        XCTAssertEqual(object["type"] as? String, "public-key")
        XCTAssertNotNil(object["clientExtensionResults"] as? [String: Any])
        let response = try XCTUnwrap(object["response"] as? [String: Any])
        XCTAssertEqual(response["clientDataJSON"] as? String, "Y2xpZW50")
        XCTAssertEqual(response["authenticatorData"] as? String, "YXV0aA")
        XCTAssertEqual(response["signature"] as? String, "c2ln")
        XCTAssertEqual(response["userHandle"] as? String, "dXNlcg")
    }

    func testRegistrationCredentialUsesWebAuthnJSONKeys() throws {
        let credential = PasskeyRegistrationCredential.make(
            credentialID: Data([9, 8, 7]),
            clientDataJSON: Data("client".utf8),
            attestationObject: Data("attestation".utf8)
        )
        let object = try jsonObject(for: credential)
        XCTAssertEqual(object["rawId"] as? String, "CQgH")
        XCTAssertNotNil(object["clientExtensionResults"] as? [String: Any])
        let response = try XCTUnwrap(object["response"] as? [String: Any])
        XCTAssertEqual(response["clientDataJSON"] as? String, "Y2xpZW50")
        XCTAssertEqual(response["attestationObject"] as? String, "YXR0ZXN0YXRpb24")
    }

    @MainActor
    func testFinishBodyKeepsCredentialKeysCamelCase() throws {
        let credential = PasskeyAssertionCredential.make(
            credentialID: Data([1]),
            clientDataJSON: Data([2]),
            authenticatorData: Data([3]),
            signature: Data([4]),
            userID: nil
        )
        let body = try FirstPartyAuthService.finishBody(
            ceremonyID: "ceremony-a",
            credential: credential,
            clientType: "ios",
            deviceName: "Test iPhone",
            nextRefreshToken: "mta_rt_next"
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["ceremony_id"] as? String, "ceremony-a")
        XCTAssertEqual(object["client_type"] as? String, "ios")
        XCTAssertEqual(object["next_refresh_token"] as? String, "mta_rt_next")
        let embedded = try XCTUnwrap(object["credential"] as? [String: Any])
        XCTAssertNotNil(embedded["rawId"])
        XCTAssertNil(embedded["raw_id"])
    }



    @MainActor
    func testCredentialDescriptorsDecodeForAuthenticationServices() throws {
        let descriptor = PasskeyCredentialDescriptor(type: "public-key", id: "AQID")
        let converted = try FirstPartyAuthService.authorizationDescriptors(for: [descriptor])

        XCTAssertEqual(converted.count, 1)
        XCTAssertEqual(converted[0].credentialID, Data([1, 2, 3]))
        XCTAssertThrowsError(
            try FirstPartyAuthService.authorizationDescriptors(
                for: [PasskeyCredentialDescriptor(type: "password", id: "AQID")]
            )
        )
    }

    func testPasskeyBeginResponseDecodesSnakeCaseCeremonyAndDescriptors() throws {
        let json = """
        {
          "ceremony_id": "ceremony-a",
          "options": {
            "challenge": "AQID",
            "rpId": "media.shimizu-technology.com",
            "userVerification": "required",
            "allowCredentials": [
              { "type": "public-key", "id": "BAUG" }
            ]
          }
        }
        """.data(using: .utf8)!
        let decoded = try APIClient.makeDecoder().decode(
            PasskeyBeginResponse<PasskeyAssertionOptions>.self,
            from: json
        )

        XCTAssertEqual(decoded.ceremonyID, "ceremony-a")
        XCTAssertEqual(decoded.options.rpID, "media.shimizu-technology.com")
        XCTAssertEqual(decoded.options.allowCredentials?.first?.id, "BAUG")
    }

    func testRecoveryRedeemRequestSendsJournaledSuccessorRefreshToken() throws {
        let request = RecoveryCodeRedeemRequest(
            code: "RCODE-123",
            clientType: "ios",
            deviceName: "Test iPhone",
            nextRefreshToken: "mta_rt_successor"
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["code"] as? String, "RCODE-123")
        XCTAssertEqual(object["client_type"] as? String, "ios")
        XCTAssertEqual(object["device_name"] as? String, "Test iPhone")
        XCTAssertEqual(object["next_refresh_token"] as? String, "mta_rt_successor")
    }


    @MainActor
    func testPasskeyLoginJournalExtractsExactSuccessorFromFinishBody() throws {
        let credential = PasskeyAssertionCredential.make(
            credentialID: Data([1]),
            clientDataJSON: Data([2]),
            authenticatorData: Data([3]),
            signature: Data([4]),
            userID: nil
        )
        let body = try FirstPartyAuthService.finishBody(
            ceremonyID: "ceremony-a",
            credential: credential,
            clientType: "ios",
            deviceName: "Test iPhone",
            nextRefreshToken: "mta_rt_successor"
        )
        let pending = PendingPasskeyLoginFinish(ceremonyID: "ceremony-a", credentialJSONData: body)

        XCTAssertEqual(pending.nextRefreshToken, "mta_rt_successor")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: pending.credentialJSONData) as? [String: Any])
        XCTAssertEqual(object["ceremony_id"] as? String, "ceremony-a")
        XCTAssertNotNil(object["credential"] as? [String: Any])
    }

    func testRecoveryRotationUsesJournalableTwoPhaseShapes() throws {
        let data = """
        { "rotation_id": "rotation-a", "codes": ["mta-1111", "mta-2222"] }
        """.data(using: .utf8)!
        let response = try APIClient.makeDecoder().decode(RecoveryCodeRotationBeginResponse.self, from: data)
        XCTAssertEqual(response.rotationID, "rotation-a")
        XCTAssertEqual(response.codes, ["mta-1111", "mta-2222"])

        let pending = PendingRecoveryCodeRotation(rotationID: response.rotationID, codes: response.codes)
        XCTAssertEqual(pending.codes.count, 2)

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let confirmData = try encoder.encode(RecoveryCodeRotationConfirmRequest(rotationID: pending.rotationID))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: confirmData) as? [String: Any])
        XCTAssertEqual(object["rotation_id"] as? String, "rotation-a")
    }

    func testRecoveryClipboardUsesLocalExpiringPasteboardItem() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let (items, options) = RecoveryCodeClipboard.payload(for: "mta-1111\nmta-2222", now: now)

        XCTAssertEqual(items.first?[UTType.utf8PlainText.identifier] as? String, "mta-1111\nmta-2222")
        XCTAssertEqual(options[.localOnly] as? Bool, true)
        XCTAssertEqual(options[.expirationDate] as? Date, now.addingTimeInterval(RecoveryCodeClipboard.expirationSeconds))
    }

    @MainActor
    func testPasskeyLoginDoesNotBeginWhenOldSessionRevocationFails() async throws {
        let controller = failingRevocationController()
        let api = RecordingFirstPartyAuthAPI()
        let service = FirstPartyAuthService(api: api, deviceSession: controller)

        do {
            try await service.signInWithPasskey()
            XCTFail("Expected revocation failure before passkey begin")
        } catch APIError.httpError(503, _, _) {
            let paths = await api.recordedPaths()
            XCTAssertEqual(paths, [])
        }
    }

    @MainActor
    func testRecoveryRedeemDoesNotRequestWhenOldSessionRevocationFails() async throws {
        let controller = failingRevocationController()
        let api = RecordingFirstPartyAuthAPI()
        let service = FirstPartyAuthService(api: api, deviceSession: controller)

        do {
            try await service.redeemRecoveryCode("mta-1111-2222")
            XCTFail("Expected revocation failure before recovery redeem")
        } catch APIError.httpError(503, _, _) {
            let paths = await api.recordedPaths()
            XCTAssertEqual(paths, [])
        }
    }

    @MainActor
    func testDefinitivePasskeyFinishFailuresDeleteJournal() async throws {
        for statusCode in [400, 401, 404] {
            let pending = try makePendingPasskeyFinish()
            let journal = InMemoryPasskeyLoginFinishJournal(pending)
            let service = FirstPartyAuthService(
                api: PasskeyFinishFailingAPI(error: .httpError(
                    statusCode: statusCode,
                    code: "invalid_challenge",
                    message: "passkey finish rejected"
                )),
                deviceSession: DeviceSessionController(store: TestDeviceSessionStore(nil), enabled: true),
                passkeyLoginJournal: journal
            )

            do {
                try await service.signInWithPasskey()
                XCTFail("Expected passkey finish status \(statusCode) to fail")
            } catch APIError.authenticationRequired(let message) {
                XCTAssertTrue(message.contains("expired"))
                XCTAssertNil(try journal.load())
            }
        }
    }

    @MainActor
    func testFreshPasskeyFinishDefinitiveFailuresDeleteSavedJournal() async throws {
        for statusCode in [400, 401, 404] {
            let pending = try makePendingPasskeyFinish()
            let journal = InMemoryPasskeyLoginFinishJournal(nil)
            let service = FirstPartyAuthService(
                api: PasskeyFinishFailingAPI(error: .httpError(
                    statusCode: statusCode,
                    code: "invalid_challenge",
                    message: "passkey finish rejected"
                )),
                deviceSession: DeviceSessionController(store: TestDeviceSessionStore(nil), enabled: true),
                passkeyLoginJournal: journal
            )

            // This is the exact boundary used by a fresh platform ceremony:
            // persist the finish body first, then submit that saved request.
            try journal.save(pending)
            do {
                try await service.completeSavedPasskeyLogin(pending)
                XCTFail("Expected fresh passkey finish status \(statusCode) to fail")
            } catch APIError.authenticationRequired(let message) {
                XCTAssertTrue(message.contains("expired"))
                XCTAssertNil(try journal.load())
            }
        }
    }

    @MainActor
    func testTransientPasskeyFinishFailuresKeepJournalForRelaunchRetry() async throws {
        for error in [
            APIError.httpError(statusCode: 503, code: "unavailable", message: "unavailable"),
            APIError.authenticationTemporarilyUnavailable(message: "offline"),
        ] {
            let pending = try makePendingPasskeyFinish()
            let journal = InMemoryPasskeyLoginFinishJournal(pending)
            let service = FirstPartyAuthService(
                api: PasskeyFinishFailingAPI(error: error),
                deviceSession: DeviceSessionController(store: TestDeviceSessionStore(nil), enabled: true),
                passkeyLoginJournal: journal
            )

            do {
                try await service.signInWithPasskey()
                XCTFail("Expected transient passkey finish to fail")
            } catch {
                XCTAssertEqual(try journal.load(), pending)
            }
        }
    }

    @MainActor
    private func makePendingPasskeyFinish() throws -> PendingPasskeyLoginFinish {
        let credential = PasskeyAssertionCredential.make(
            credentialID: Data([1]),
            clientDataJSON: Data([2]),
            authenticatorData: Data([3]),
            signature: Data([4]),
            userID: nil
        )
        return PendingPasskeyLoginFinish(
            ceremonyID: "ceremony-a",
            credentialJSONData: try FirstPartyAuthService.finishBody(
                ceremonyID: "ceremony-a",
                credential: credential,
                clientType: "ios",
                deviceName: "Test iPhone",
                nextRefreshToken: "mta_rt_successor"
            )
        )
    }

    @MainActor
    private func failingRevocationController() -> DeviceSessionController {
        let pair = DeviceSessionPair(
            sessionID: "session-old",
            userID: "server-old",
            accessToken: "mta_at_old",
            accessExpiresAt: .distantFuture,
            refreshToken: "mta_rt_old",
            inactiveExpiresAt: .distantFuture
        )
        return DeviceSessionController(
            transport: FailingRevocationTransport(),
            baseURL: URL(string: "https://example.test/api/v1")!,
            store: TestDeviceSessionStore(StoredDeviceSession(pair: pair, source: .passkey)),
            enabled: true
        )
    }



    @MainActor
    func testExpiredRecoveryRotationConfirmDeletesJournal() async throws {
        let journal = InMemoryRecoveryCodeRotationJournal(
            PendingRecoveryCodeRotation(rotationID: "rotation-expired", codes: ["mta-1111"])
        )
        let service = FirstPartyAuthService(
            api: StatusFailingFirstPartyAuthAPI(statusCode: 404),
            deviceSession: DeviceSessionController(store: TestDeviceSessionStore(nil), enabled: true),
            recoveryRotationJournal: journal
        )

        do {
            _ = try await service.confirmRecoveryCodeRotation()
            XCTFail("Expected expired rotation to fail")
        } catch APIError.authenticationRequired(let message) {
            XCTAssertTrue(message.contains("Generate a new set"))
            XCTAssertNil(try journal.load())
        }
    }

    @MainActor
    func testTransientRecoveryRotationConfirmKeepsJournal() async throws {
        let pending = PendingRecoveryCodeRotation(rotationID: "rotation-retry", codes: ["mta-2222"])
        let journal = InMemoryRecoveryCodeRotationJournal(pending)
        let service = FirstPartyAuthService(
            api: StatusFailingFirstPartyAuthAPI(statusCode: 503),
            deviceSession: DeviceSessionController(store: TestDeviceSessionStore(nil), enabled: true),
            recoveryRotationJournal: journal
        )

        do {
            _ = try await service.confirmRecoveryCodeRotation()
            XCTFail("Expected transient rotation confirm failure")
        } catch APIError.httpError(503, _, _) {
            XCTAssertEqual(try journal.load(), pending)
        }
    }

    @MainActor
    func testPreCanceledAuthorizationDoesNotStartController() async throws {
        let service = FirstPartyAuthService(
            api: RecordingFirstPartyAuthAPI(),
            deviceSession: DeviceSessionController(store: TestDeviceSessionStore(nil), enabled: true)
        )
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: "media.shimizu-technology.com"
        )
        let request = provider.createCredentialAssertionRequest(challenge: Data([1, 2, 3]))
        let task = Task { @MainActor () throws -> ASAuthorization in
            await Task.yield()
            return try await service.perform(request: request)
        }

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected pre-canceled authorization to throw before starting")
        } catch {
            XCTAssertTrue(error is CancellationError || FirstPartyAuthService.isCancellation(error))
            XCTAssertEqual(service.authorizationRequestStartCountForTesting, 0)
        }
    }

    @MainActor
    func testAuthorizationDelegateCancellationCompletesExactlyOnce() {
        var results: [Result<ASAuthorization, Error>] = []
        let delegate = PasskeyAuthorizationDelegate { result in
            results.append(result)
        }

        delegate.cancel()
        delegate.cancel()

        XCTAssertEqual(results.count, 1)
        guard case .failure(let error) = results[0] else {
            XCTFail("Expected cancellation failure")
            return
        }
        XCTAssertTrue(FirstPartyAuthService.isCancellation(error))
    }

    @MainActor
    func testAuthorizationCancellationIsRecognized() {
        let error = NSError(
            domain: "com.apple.AuthenticationServices.AuthorizationError",
            code: ASAuthorizationError.Code.canceled.rawValue
        )
        XCTAssertTrue(FirstPartyAuthService.isCancellation(error))
        XCTAssertTrue(FirstPartyAuthService.isCancellation(FirstPartyAuthError.canceled))
    }

    private func jsonObject<T: Encodable>(for value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

@MainActor
private final class TestDeviceSessionStore: DeviceSessionStoring {
    var value: StoredDeviceSession?
    var pendingBootstrap: PendingDeviceSessionBootstrap?
    private var ownerMappings: [String: String] = [:]

    init(_ value: StoredDeviceSession?) { self.value = value }

    func load() -> StoredDeviceSession? { value }
    func save(_ value: StoredDeviceSession) throws { self.value = value }
    func delete() { value = nil }
    func loadPendingBootstrap() throws -> PendingDeviceSessionBootstrap? { pendingBootstrap }
    func savePendingBootstrap(_ value: PendingDeviceSessionBootstrap) throws { pendingBootstrap = value }
    func deletePendingBootstrap() { pendingBootstrap = nil }
    func localOwnerID(for clerkID: String) -> String? { ownerMappings[clerkID] }
    func clerkID(forLocalOwnerID ownerID: String) -> String? { ownerMappings.first(where: { $0.value == ownerID })?.key }
    func saveLocalOwnerID(_ ownerID: String, for clerkID: String) { ownerMappings[clerkID] = ownerID }
    func removeLocalOwnerID(for clerkID: String) { ownerMappings.removeValue(forKey: clerkID) }
}

@MainActor
private final class InMemoryPasskeyLoginFinishJournal: PasskeyLoginFinishJournaling {
    private var pending: PendingPasskeyLoginFinish?

    init(_ pending: PendingPasskeyLoginFinish?) {
        self.pending = pending
    }

    func load() throws -> PendingPasskeyLoginFinish? { pending }
    func save(_ value: PendingPasskeyLoginFinish) throws { pending = value }
    func delete() { pending = nil }
}

@MainActor
private final class InMemoryRecoveryCodeRotationJournal: RecoveryCodeRotationJournaling {
    private var pending: PendingRecoveryCodeRotation?

    init(_ pending: PendingRecoveryCodeRotation?) {
        self.pending = pending
    }

    func load() throws -> PendingRecoveryCodeRotation? { pending }
    func save(_ value: PendingRecoveryCodeRotation) throws { pending = value }
    func delete() { pending = nil }
}

private actor FailingRevocationTransport: DeviceSessionTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let data = Data("{\"error\":\"unavailable\",\"message\":\"unavailable\"}".utf8)
        return (
            data,
            HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }
}

private actor RecordingFirstPartyAuthAPI: FirstPartyAuthAPI {
    private var paths: [String] = []

    func recordedPaths() -> [String] { paths }

    func get<T>(_ path: String, expectedOwnerID: String?) async throws -> T where T: Decodable {
        paths.append("GET \(path)")
        throw APIError.invalidResponse
    }

    func post<T, B>(_ path: String, body: B, expectedOwnerID: String?) async throws -> T where T: Decodable, B: Encodable {
        paths.append("POST \(path)")
        throw APIError.invalidResponse
    }

    func postPublic<T, B>(_ path: String, body: B) async throws -> T where T: Decodable, B: Encodable {
        paths.append("POST_PUBLIC \(path)")
        throw APIError.invalidResponse
    }

    func postJSON<T>(_ path: String, bodyData: Data, authenticated: Bool) async throws -> T where T: Decodable {
        paths.append("POST_JSON \(path)")
        throw APIError.invalidResponse
    }
}

private actor StatusFailingFirstPartyAuthAPI: FirstPartyAuthAPI {
    let statusCode: Int

    init(statusCode: Int) { self.statusCode = statusCode }

    func get<T>(_ path: String, expectedOwnerID: String?) async throws -> T where T: Decodable {
        throw APIError.invalidResponse
    }

    func post<T, B>(_ path: String, body: B, expectedOwnerID: String?) async throws -> T where T: Decodable, B: Encodable {
        throw APIError.httpError(statusCode: statusCode, code: "rotation_unavailable", message: "rotation unavailable")
    }

    func postPublic<T, B>(_ path: String, body: B) async throws -> T where T: Decodable, B: Encodable {
        throw APIError.invalidResponse
    }

    func postJSON<T>(_ path: String, bodyData: Data, authenticated: Bool) async throws -> T where T: Decodable {
        throw APIError.invalidResponse
    }
}

private actor PasskeyFinishFailingAPI: FirstPartyAuthAPI {
    let error: APIError

    init(error: APIError) { self.error = error }

    func get<T>(_ path: String, expectedOwnerID: String?) async throws -> T where T: Decodable {
        throw APIError.invalidResponse
    }

    func post<T, B>(_ path: String, body: B, expectedOwnerID: String?) async throws -> T where T: Decodable, B: Encodable {
        throw APIError.invalidResponse
    }

    func postPublic<T, B>(_ path: String, body: B) async throws -> T where T: Decodable, B: Encodable {
        throw APIError.invalidResponse
    }

    func postJSON<T>(_ path: String, bodyData: Data, authenticated: Bool) async throws -> T where T: Decodable {
        throw error
    }
}
