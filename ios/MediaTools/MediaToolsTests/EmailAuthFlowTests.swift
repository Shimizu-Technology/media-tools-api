import XCTest
@testable import MediaTools

/// A scripted server. Each path answers with queued results in order; the JSON
/// goes through the real decoder, so wrong field names fail here.
private actor ScriptedAuthAPI: FirstPartyAuthAPI {
    enum Reply {
        case json(String)
        case failure(Error)
    }

    private var replies: [String: [Reply]] = [:]
    private(set) var calls: [String] = []
    private(set) var bodies: [String: [[String: Any]]] = [:]

    func script(_ path: String, _ reply: Reply) {
        replies[path, default: []].append(reply)
    }

    private func answer<T: Decodable>(_ path: String) throws -> T {
        calls.append(path)
        guard var queue = replies[path], !queue.isEmpty else {
            throw URLError(.badServerResponse)
        }
        let reply = queue.removeFirst()
        replies[path] = queue
        switch reply {
        case .json(let text):
            return try APIClient.makeDecoder().decode(T.self, from: Data(text.utf8))
        case .failure(let error):
            throw error
        }
    }

    private func record<B: Encodable>(_ path: String, _ body: B) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let object = try JSONSerialization.jsonObject(with: encoder.encode(body)) as? [String: Any]
        bodies[path, default: []].append(object ?? [:])
    }

    func delete(_ path: String) async throws {
        calls.append("DELETE \(path)")
    }

    func get<T: Decodable>(_ path: String, expectedOwnerID: String?) async throws -> T {
        try answer(path)
    }

    func post<T: Decodable, B: Encodable>(_ path: String, body: B, expectedOwnerID: String?) async throws -> T {
        try record(path, body)
        return try answer(path)
    }

    func postPublic<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        try record(path, body)
        return try answer(path)
    }

    func postJSON<T: Decodable>(_ path: String, bodyData: Data, authenticated: Bool) async throws -> T {
        try answer(path)
    }

    func lastBody(_ path: String) -> [String: Any] { bodies[path]?.last ?? [:] }
    func callCount(_ path: String) -> Int { calls.filter { $0 == path }.count }
}

@MainActor
private final class MemoryLoginJournal: PasswordLoginJournaling {
    var pending: PendingPasswordLogin?
    func load() throws -> PendingPasswordLogin? { pending }
    func save(_ value: PendingPasswordLogin) throws { pending = value }
    func delete() { pending = nil }
}

@MainActor
final class EmailAuthFlowTests: XCTestCase {
    private let receipt = #"{"message":"If this request is eligible, an email will arrive shortly"}"#
    private let proofDone = #"{"verified":true,"sign_in_required":true}"#
    private var store: UpdateSessionStore!
    private var session: DeviceSessionController!
    private var journal: MemoryLoginJournal!
    private var api: ScriptedAuthAPI!
    private var service: FirstPartyAuthService!

    override func setUp() async throws {
        store = UpdateSessionStore(nil)
        session = DeviceSessionController(
            transport: NoNetwork(),
            baseURL: URL(string: "https://example.test/api/v1")!,
            store: store,
            retiredLegacyIdentities: UpdateRetiredIdentities()
        )
        journal = MemoryLoginJournal()
        api = ScriptedAuthAPI()
        service = FirstPartyAuthService(api: api, deviceSession: session, passwordLoginJournal: journal)
    }


    /// The login reply must echo the journaled successor, which does not exist
    /// until the request starts, so a fake needs a small trick: a journal entry
    /// saved up front is reused rather than replaced.
    private func prepareLogin(email: String, userID: String = "server-a") async throws {
        let successor = try DeviceSessionController.randomRefreshToken()
        journal.pending = PendingPasswordLogin(email: email, nextRefreshToken: successor)
        await api.script("/auth/password/login", .json("""
        {"session_id":"session-new","user_id":"\(userID)","access_token":"access",
         "access_expires_at":"2099-01-01T00:00:00Z","refresh_token":"\(successor)",
         "inactive_expires_at":"2099-01-01T00:00:00Z"}
        """))
    }

    func testSignUpVerifiesThenSignsIn() async throws {
        await api.script("/auth/signup", .json(receipt))
        await api.script("/auth/signup/verify", .json(proofDone))
        try await prepareLogin(email: "person@example.com")

        try await service.beginSignUp(email: " Person@Example.com ", name: "  ")
        let start = await api.lastBody("/auth/signup")
        XCTAssertEqual(start["email"] as? String, "person@example.com")
        XCTAssertNil(start["name"], "A blank name is not sent")
        XCTAssertNil(start["password"], "No password may travel before the email is proved")

        try await service.finishSignUp(email: "person@example.com", code: "123456", password: "a long enough password")

        let verify = await api.lastBody("/auth/signup/verify")
        XCTAssertEqual(verify["code"] as? String, "123456")
        XCTAssertEqual(verify["password"] as? String, "a long enough password")
        XCTAssertEqual(session.activeUserID, "server-a")
        XCTAssertEqual(store.value?.source, .passkey, "Older builds must be able to read this session")
        XCTAssertNil(journal.pending)
    }

    func testLostProofResponseRecoversBySigningIn() async throws {
        await api.script("/auth/password/reset", .failure(URLError(.networkConnectionLost)))
        await api.script("/auth/password/reset", .failure(
            APIError.httpError(statusCode: 400, code: "invalid_code", message: "Code invalid")
        ))
        try await prepareLogin(email: "person@example.com")

        do {
            try await service.finishPasswordReset(email: "person@example.com", code: "123456", password: "a long enough password")
            XCTFail("The first attempt has no answer yet")
        } catch is URLError {}
        XCTAssertNil(session.activeUserID)

        try await service.finishPasswordReset(email: "person@example.com", code: "123456", password: "a long enough password")
        XCTAssertEqual(session.activeUserID, "server-a")
    }

    func testAnInvalidCodeWithNoLostResponseIsJustAnInvalidCode() async throws {
        await api.script("/auth/password/reset", .failure(
            APIError.httpError(statusCode: 400, code: "invalid_code", message: "Code invalid")
        ))
        do {
            try await service.finishPasswordReset(email: "person@example.com", code: "000000", password: "a long enough password")
            XCTFail("Expected rejection")
        } catch {
            XCTAssertTrue(AuthCopy.message(for: error, fallback: "").contains("Send a new code"))
        }
        let logins = await api.callCount("/auth/password/login")
        XCTAssertEqual(logins, 0, "A wrong code must not spend a password guess")
    }

    func testAcceptedProofWithFailedSignInAsksForSignInRatherThanARetry() async throws {
        await api.script("/auth/signup/verify", .json(proofDone))
        await api.script("/auth/password/login", .failure(URLError(.notConnectedToInternet)))
        do {
            try await service.finishSignUp(email: "person@example.com", code: "123456", password: "a long enough password")
            XCTFail("Expected the sign-in step to fail")
        } catch FirstPartyAuthError.signInNeededAfterProof {}
    }

    func testResetWorksForAnAccountThatNeverHadAPassword() async throws {
        await api.script("/auth/password/forgot", .json(receipt))
        try await service.beginPasswordReset(email: "clerk-linked@example.com")
        let body = await api.lastBody("/auth/password/forgot")
        XCTAssertEqual(body["email"] as? String, "clerk-linked@example.com")
        XCTAssertEqual(body.count, 1)
    }

    func testChangePasswordSendsTheCurrentPasswordUnderTheContractKey() async throws {
        store.value = signedInSession()
        session = DeviceSessionController(transport: NoNetwork(), store: store, retiredLegacyIdentities: UpdateRetiredIdentities())
        service = FirstPartyAuthService(api: api, deviceSession: session, passwordLoginJournal: journal)
        await api.script("/auth/password", .json(#"{"configured":true}"#))

        _ = try await service.setPassword("a brand new password", currentPassword: "the old password")

        let body = await api.lastBody("/auth/password")
        XCTAssertEqual(body["password"] as? String, "a brand new password")
        XCTAssertEqual(body["current_password"] as? String, "the old password")
    }

    func testFirstPasswordOmitsCurrentPassword() async throws {
        store.value = signedInSession()
        session = DeviceSessionController(transport: NoNetwork(), store: store, retiredLegacyIdentities: UpdateRetiredIdentities())
        service = FirstPartyAuthService(api: api, deviceSession: session, passwordLoginJournal: journal)
        await api.script("/auth/password", .json(#"{"configured":true}"#))

        _ = try await service.setPassword("a brand new password")

        let body = await api.lastBody("/auth/password")
        XCTAssertNil(body["current_password"])
    }

    func testEmailChangeSignsBackInWithTheNewEmail() async throws {
        store.value = signedInSession()
        session = DeviceSessionController(transport: RevokedEverywhere(), baseURL: URL(string: "https://example.test/api/v1")!, store: store, retiredLegacyIdentities: UpdateRetiredIdentities())
        service = FirstPartyAuthService(api: api, deviceSession: session, passwordLoginJournal: journal)
        await api.script("/auth/email/change", .json(receipt))
        await api.script("/auth/email/change/verify", .json(proofDone))
        try await prepareLogin(email: "new@example.com")

        try await service.beginEmailChange(newEmail: "NEW@example.com", currentPassword: "the password")
        let begin = await api.lastBody("/auth/email/change")
        XCTAssertEqual(begin["email"] as? String, "new@example.com")
        XCTAssertEqual(begin["current_password"] as? String, "the password")

        try await service.finishEmailChange(newEmail: "new@example.com", code: "123456", currentPassword: "the password")

        XCTAssertEqual(session.activeUserID, "server-a", "The same account continues")
        XCTAssertEqual(store.value?.pair.sessionID, "session-new")
    }

    func testALostResponseForOneAddressNeverSignsInAnother() async throws {
        let invalid = APIError.httpError(statusCode: 400, code: "invalid_code", message: "Code invalid")
        await api.script("/auth/password/reset", .failure(URLError(.timedOut)))
        await api.script("/auth/password/reset", .failure(invalid))
        try await prepareLogin(email: "other@example.com")

        do {
            try await service.finishPasswordReset(email: "first@example.com", code: "123456", password: "a long enough password")
            XCTFail("The first attempt has no answer yet")
        } catch is URLError {}

        do {
            try await service.finishPasswordReset(email: "other@example.com", code: "000000", password: "a long enough password")
            XCTFail("A wrong code for another address must stay wrong")
        } catch {
            XCTAssertTrue(AuthCopy.message(for: error, fallback: "").contains("Send a new code"))
        }
        let logins = await api.callCount("/auth/password/login")
        XCTAssertEqual(logins, 0)
        XCTAssertNil(session.activeUserID)
    }

    func testALostResponseOnlyCoversTheExactCodeAndPasswordThatLostIt() async throws {
        let invalid = APIError.httpError(statusCode: 400, code: "invalid_code", message: "Code invalid")
        await api.script("/auth/password/reset", .failure(URLError(.networkConnectionLost)))
        await api.script("/auth/password/reset", .failure(invalid))
        await api.script("/auth/password/reset", .failure(invalid))
        try await prepareLogin(email: "person@example.com")

        do {
            try await service.finishPasswordReset(email: "person@example.com", code: "123456", password: "a long enough password")
            XCTFail("The first attempt has no answer yet")
        } catch is URLError {}

        // A different wrong code with the account's current password must not
        // sign in or report a reset that the server never verified.
        do {
            try await service.finishPasswordReset(email: "person@example.com", code: "000000", password: "a long enough password")
            XCTFail("A different code must stay an invalid code")
        } catch {
            XCTAssertTrue(AuthCopy.message(for: error, fallback: "").contains("Send a new code"))
        }
        let logins = await api.callCount("/auth/password/login")
        XCTAssertEqual(logins, 0)
        XCTAssertNil(session.activeUserID)

        // The exact attempt that lost its reply still recovers.
        try await service.finishPasswordReset(email: "person@example.com", code: "123456", password: "a long enough password")
        XCTAssertEqual(session.activeUserID, "server-a")
    }

    func testAnInvalidCodeOnAStillValidSessionNeverSignsInOverIt() async throws {
        store.value = signedInSession()
        session = DeviceSessionController(transport: NoNetwork(), baseURL: URL(string: "https://example.test/api/v1")!, store: store, retiredLegacyIdentities: UpdateRetiredIdentities())
        service = FirstPartyAuthService(api: api, deviceSession: session, passwordLoginJournal: journal)
        await api.script("/auth/email/change/verify", .failure(URLError(.networkConnectionLost)))
        await api.script("/auth/email/change/verify", .failure(
            APIError.httpError(statusCode: 400, code: "invalid_code", message: "Code invalid")
        ))
        await api.script("/auth/me", .json(#"{"id":"server-a","email":"old@example.com","name":"Person"}"#))
        try await prepareLogin(email: "new@example.com")

        do {
            try await service.finishEmailChange(newEmail: "new@example.com", code: "123456", currentPassword: "the password")
            XCTFail("The first attempt has no answer yet")
        } catch is URLError {}
        do {
            try await service.finishEmailChange(newEmail: "new@example.com", code: "123456", currentPassword: "the password")
            XCTFail("The change never committed, so the code is simply wrong")
        } catch {
            XCTAssertTrue(AuthCopy.message(for: error, fallback: "").contains("Send a new code"))
        }

        let logins = await api.callCount("/auth/password/login")
        XCTAssertEqual(logins, 0, "Signing in would have revoked a session that is still good")
        XCTAssertEqual(store.value?.pair.sessionID, "session-old")
        XCTAssertEqual(session.activeUserID, "server-a")
    }

    func testAnInvalidCodeOnARevokedSessionSignsInBecauseTheChangeCommitted() async throws {
        store.value = signedInSession()
        session = DeviceSessionController(transport: RevokedEverywhere(), baseURL: URL(string: "https://example.test/api/v1")!, store: store, retiredLegacyIdentities: UpdateRetiredIdentities())
        service = FirstPartyAuthService(api: api, deviceSession: session, passwordLoginJournal: journal)
        await api.script("/auth/email/change/verify", .failure(URLError(.networkConnectionLost)))
        await api.script("/auth/email/change/verify", .failure(
            APIError.httpError(statusCode: 400, code: "invalid_code", message: "Code invalid")
        ))
        await api.script("/auth/me", .failure(APIError.httpError(statusCode: 401, code: "unauthorized", message: "")))
        try await prepareLogin(email: "new@example.com")

        do {
            try await service.finishEmailChange(newEmail: "new@example.com", code: "123456", currentPassword: "the password")
            XCTFail("The first attempt has no answer yet")
        } catch is URLError {}
        try await service.finishEmailChange(newEmail: "new@example.com", code: "123456", currentPassword: "the password")

        XCTAssertEqual(session.activeUserID, "server-a")
        XCTAssertEqual(store.value?.pair.sessionID, "session-new")
    }

    func testAnUncheckableSessionKeepsTheLostResponseNoteForTheNextTry() async throws {
        store.value = signedInSession()
        session = DeviceSessionController(transport: RevokedEverywhere(), baseURL: URL(string: "https://example.test/api/v1")!, store: store, retiredLegacyIdentities: UpdateRetiredIdentities())
        service = FirstPartyAuthService(api: api, deviceSession: session, passwordLoginJournal: journal)
        let invalid = APIError.httpError(statusCode: 400, code: "invalid_code", message: "Code invalid")
        await api.script("/auth/email/change/verify", .failure(URLError(.networkConnectionLost)))
        await api.script("/auth/email/change/verify", .failure(invalid))
        await api.script("/auth/me", .failure(URLError(.notConnectedToInternet)))
        await api.script("/auth/email/change/verify", .failure(invalid))
        await api.script("/auth/me", .failure(APIError.httpError(statusCode: 401, code: "unauthorized", message: "")))
        try await prepareLogin(email: "new@example.com")

        do { try await service.finishEmailChange(newEmail: "new@example.com", code: "123456", currentPassword: "pw"); XCTFail("lost") } catch is URLError {}
        do { try await service.finishEmailChange(newEmail: "new@example.com", code: "123456", currentPassword: "pw"); XCTFail("uncheckable") } catch is URLError {}
        let loginsBefore = await api.callCount("/auth/password/login")
        XCTAssertEqual(loginsBefore, 0, "No sign-in while the session's state is unknown")

        // The note survived, so the next answer can still be recognized.
        try await service.finishEmailChange(newEmail: "new@example.com", code: "123456", currentPassword: "pw")
        let loginsAfter = await api.callCount("/auth/password/login")
        XCTAssertEqual(loginsAfter, 1)
    }

    // MARK: - Error copy

    func testRejectedLoginMentionsTheGuessGapAndKeepsTheRetryCredential() async throws {
        await api.script("/auth/password/login", .failure(
            APIError.httpError(statusCode: 401, code: "invalid_credentials", message: "Email or password is incorrect")
        ))
        do {
            try await service.signInWithPassword(email: "person@example.com", password: "typo")
            XCTFail("Expected rejection")
        } catch APIError.authenticationRequired(let message) {
            XCTAssertTrue(message.contains("incorrect"))
            XCTAssertTrue(message.contains("30 seconds"), "A correct password can be rejected inside the gap")
        }
        XCTAssertNotNil(journal.pending)
    }

    func testRateLimitedLoginExplainsTheGapInsteadOfTheWindow() async throws {
        await api.script("/auth/password/login", .failure(
            APIError.rateLimited(retryAfter: 900, message: "Too many unsuccessful attempts")
        ))
        do {
            try await service.signInWithPassword(email: "person@example.com", password: "typo")
            XCTFail("Expected rejection")
        } catch APIError.authenticationRequired(let message) {
            XCTAssertTrue(message.contains("30 seconds"))
            XCTAssertFalse(message.contains("15"), "Retry-After is the window, not how long to wait")
        }
        XCTAssertNotNil(journal.pending, "Local input and the retry credential both survive")
    }

    func testOtherRateLimitsHonorRetryAfter() {
        XCTAssertTrue(AuthCopy.message(
            for: APIError.rateLimited(retryAfter: 240, message: ""), fallback: ""
        ).contains("4 minutes"))
        XCTAssertTrue(AuthCopy.message(
            for: APIError.rateLimited(retryAfter: 20, message: ""), fallback: ""
        ).contains("a minute"))
    }

    func testContractErrorsHaveReadableCopyAndNoStatusNumbers() {
        for code in [
            "weak_password", "password_compromised", "invalid_code", "invalid_credentials",
            "current_password_required", "email_verification_required", "signup_disabled",
            "password_required", "credential_changed", "authentication_unavailable",
        ] {
            let message = AuthCopy.message(
                for: APIError.httpError(statusCode: 400, code: code, message: "raw"),
                fallback: "fallback"
            )
            XCTAssertFalse(message.isEmpty, code)
            XCTAssertNotEqual(message, "raw", code)
            XCTAssertFalse(message.contains("HTTP"), code)
        }
        XCTAssertEqual(AuthCopy.emailReceipt, "If this request is eligible, an email will arrive shortly")
    }

    func testPasswordRuleCountsNormalizedCharacters() {
        XCTAssertFalse(NewPasswordRule.isLongEnough(String(repeating: "a", count: 11)))
        XCTAssertTrue(NewPasswordRule.isLongEnough(String(repeating: "a", count: 12)))
        XCTAssertTrue(NewPasswordRule.isLongEnough(String(repeating: "a", count: 128)))
        XCTAssertFalse(NewPasswordRule.isLongEnough(String(repeating: "a", count: 129)))
        // A decomposed e-acute is one character to the server after NFC.
        XCTAssertFalse(NewPasswordRule.isLongEnough(String(repeating: "e\u{301}", count: 11)))
        XCTAssertEqual(
            NewPasswordRule.problem(password: String(repeating: "a", count: 12), confirmation: "different"),
            "The passwords do not match."
        )
    }

    // MARK: - A typed password is never sent twice

    func testA401ThatRejectsAPasswordIsNotASessionRejection() {
        func response(_ status: Int, _ error: String) -> (Data, URLResponse) {
            let url = URL(string: "https://example.test")!
            return (
                Data(#"{"error":"\#(error)","message":"x","code":\#(status)}"#.utf8),
                HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            )
        }
        XCTAssertFalse(APIClient.isSessionRejection(response(401, "current_password_required")))
        XCTAssertFalse(APIClient.isSessionRejection(response(401, "invalid_credentials")))
        XCTAssertTrue(APIClient.isSessionRejection(response(401, "invalid_session")))
        XCTAssertFalse(APIClient.isSessionRejection(response(403, "invalid_session")))
    }

    // MARK: - Server shapes

    func testDecodesServerShapes() throws {
        let decoder = APIClient.makeDecoder()
        let usage = try decoder.decode(AccountUsage.self, from: Data(#"""
        {"month":"2026-11-01T00:00:00Z","transcription_seconds":60,"transcription_limit_seconds":18000,
         "ai_requests":2,"ai_request_limit":1000,"exempt":false}
        """#.utf8))
        XCTAssertEqual(usage.transcriptionLimitSeconds, 18000)
        XCTAssertEqual(usage.aiRequestLimit, 1000)

        let list = try decoder.decode(DeviceSessionListResponse.self, from: Data(#"""
        {"sessions":[{"id":"s1","client_type":"ios","device_name":"Phone",
         "created_at":"2026-11-01T00:00:00Z","last_used_at":"2026-11-02T00:00:00.123Z",
         "inactive_expires_at":"2099-01-01T00:00:00Z"},
         {"id":"s2","client_type":"web","device_name":"","created_at":"2026-11-01T00:00:00Z",
          "last_used_at":"2026-11-02T00:00:00Z","inactive_expires_at":"2099-01-01T00:00:00Z",
          "revoked_at":"2026-11-03T00:00:00Z"}]}
        """#.utf8))
        XCTAssertEqual(list.sessions.filter(\.isUsable).map(\.id), ["s1"])

        let profile = try decoder.decode(AccountProfile.self, from: Data(#"""
        {"id":"server-a","email":"a@example.com","name":"","clerk_id":"user_2abc",
         "onboarding_required":false,"created_at":"2026-11-01T00:00:00Z","email_verified":true}
        """#.utf8))
        XCTAssertEqual(profile.clerkId, "user_2abc")
        XCTAssertEqual(profile.emailVerified, true)

        let health = try decoder.decode(HealthResponse.self, from: Data(#"""
        {"signup_enabled":true,"auth_capabilities":{"email_codes":true,"password_reset":true,"optional_passkeys":true},
         "status":"ok","version":"1","database":"ok","workers":1,"password_auth_enabled":true}
        """#.utf8))
        let availability = AuthAvailability(health: health)
        XCTAssertEqual(availability, AuthAvailability(passwordAuth: true, signup: true, passwordReset: true))
    }

    func testSignUpStaysHiddenUnlessTheServerSaysOtherwise() throws {
        XCTAssertFalse(AuthAvailability.unknown.signup)
        let older = try APIClient.makeDecoder().decode(HealthResponse.self, from: Data(#"""
        {"status":"ok","version":"1","database":"ok","workers":1,"password_auth_enabled":true}
        """#.utf8))
        XCTAssertFalse(AuthAvailability(health: older).signup)
        XCTAssertEqual(AuthAvailability(health: older).passwordAuth, true)
    }

    private func signedInSession() -> StoredDeviceSession {
        StoredDeviceSession(
            pair: DeviceSessionPair(
                sessionID: "session-old", userID: "server-a", accessToken: "access",
                accessExpiresAt: .distantFuture, refreshToken: "refresh", inactiveExpiresAt: .distantFuture
            ),
            source: .passkey
        )
    }
}

private struct NoNetwork: DeviceSessionTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

/// What the server does after an email change: every old credential is dead.
private struct RevokedEverywhere: DeviceSessionTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
    }
}
