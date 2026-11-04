import XCTest
@testable import MediaTools

@MainActor
private final class MemoryAccountDeletionJournal: AccountDeletionJournaling {
    var value: PendingAccountDeletion?

    func load() throws -> PendingAccountDeletion? { value }
    func save(_ value: PendingAccountDeletion) throws { self.value = value }
    func delete() { value = nil }
}

private actor MockAccountDeletionAPI: AccountDeletionAPI {
    enum RequestResult: Equatable {
        case success
        case failure
        case definitiveHTTPFailure
        case ambiguousHTTPFailure
    }

    enum ReceiptResult: Equatable {
        case confirmed
        case unconfirmed
        case unavailable
    }

    private let requestResult: RequestResult
    private let receiptResult: ReceiptResult
    private var requested: [(ownerID: String, receiptToken: String)] = []

    init(requestResult: RequestResult, receiptResult: ReceiptResult) {
        self.requestResult = requestResult
        self.receiptResult = receiptResult
    }

    func requestAccountDeletion(ownerID: String, receiptToken: String, currentPassword: String?) async throws {
        requested.append((ownerID, receiptToken))
        switch requestResult {
        case .success:
            return
        case .failure:
            throw URLError(.timedOut)
        case .definitiveHTTPFailure:
            throw APIError.httpError(
                statusCode: 503,
                code: "account_deletion_unavailable",
                message: "Account deletion is unavailable"
            )
        case .ambiguousHTTPFailure:
            throw APIError.httpError(
                statusCode: 503,
                message: "Upstream response was unavailable"
            )
        }
    }

    func accountDeletionReceiptConfirmed(_ receiptToken: String) async throws -> Bool {
        switch receiptResult {
        case .confirmed: true
        case .unconfirmed: false
        case .unavailable: throw URLError(.cannotConnectToHost)
        }
    }

    func requests() -> [(ownerID: String, receiptToken: String)] { requested }
}

@MainActor
private final class RecordingDeletionCleaner: AccountDeletionLocalDataRemoving {
    private(set) var removedOwners: [String] = []
    func removeLocalAccountData(ownerID: String) async { removedOwners.append(ownerID) }
}

@MainActor
private final class AccountSwitchingDeletionCleaner: AccountDeletionLocalDataRemoving {
    private let switchAccount: () -> Void

    init(switchAccount: @escaping () -> Void) {
        self.switchAccount = switchAccount
    }

    func removeLocalAccountData(ownerID: String) async {
        await Task.yield()
        switchAccount()
    }
}

@MainActor
private final class AccountDeletionDeviceSessionStore: DeviceSessionStoring {
    var value: StoredDeviceSession?
    private var mappings: [String: String] = [:]

    init(_ value: StoredDeviceSession?) { self.value = value }
    func load() -> StoredDeviceSession? { value }
    func save(_ value: StoredDeviceSession) throws { self.value = value }
    func delete() { value = nil }
    func localOwnerID(for clerkID: String) -> String? { mappings[clerkID] }
    func clerkID(forLocalOwnerID ownerID: String) -> String? {
        mappings.first(where: { $0.value == ownerID })?.key
    }
    func saveLocalOwnerID(_ ownerID: String, for clerkID: String) { mappings[clerkID] = ownerID }
    func removeLocalOwnerID(for clerkID: String) { mappings.removeValue(forKey: clerkID) }
}

final class AccountDeletionRecoveryServiceTests: XCTestCase {
    @MainActor
    func testAWrongPasswordSaysSoAndLeavesNothingPending() async throws {
        let journal = MemoryAccountDeletionJournal()
        let service = AccountDeletionRecoveryService(
            api: PasswordRejectingDeletionAPI(),
            journal: journal
        )
        do {
            _ = try await service.requestDeletion(ownerID: "owner-a", currentPassword: "wrong")
            XCTFail("Expected rejection")
        } catch AccountDeletionRecoveryError.currentPasswordRejected {
            XCTAssertNil(journal.value, "Nothing was deleted, so nothing may retry")
        }
    }

    func testDeletionBodyCarriesTheCurrentPasswordOnlyWhenGiven() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let withPassword = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(
            AccountDeletionRequestBody(confirmation: "DELETE", deletionReceiptToken: "t", currentPassword: "p")
        )) as? [String: Any])
        XCTAssertEqual(withPassword["current_password"] as? String, "p")
        let without = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(
            AccountDeletionRequestBody(confirmation: "DELETE", deletionReceiptToken: "t")
        )) as? [String: Any])
        XCTAssertNil(without["current_password"])
    }

    @MainActor
    func testPreparePersistsAndReusesExactOwnerBoundReceipt() throws {
        let journal = MemoryAccountDeletionJournal()
        let api = MockAccountDeletionAPI(requestResult: .success, receiptResult: .unconfirmed)
        let service = AccountDeletionRecoveryService(api: api, journal: journal)

        let first = try service.prepare(ownerID: "owner-a")
        let retry = try service.prepare(ownerID: "owner-a")

        XCTAssertEqual(first, retry)
        XCTAssertEqual(journal.value, first)
        XCTAssertTrue(first.receiptToken.hasPrefix("mta_del_"))
        XCTAssertEqual(first.receiptToken.count, 51)
        XCTAssertThrowsError(try service.prepare(ownerID: "owner-b")) { error in
            XCTAssertEqual(error as? AccountDeletionRecoveryError, .pendingForAnotherAccount)
        }
        XCTAssertEqual(journal.value, first)
    }

    @MainActor
    func testSuccessfulDeleteReturnsJournaledReceiptWithoutStatusInference() async throws {
        let journal = MemoryAccountDeletionJournal()
        let api = MockAccountDeletionAPI(requestResult: .success, receiptResult: .unconfirmed)
        let service = AccountDeletionRecoveryService(api: api, journal: journal)

        let pending = try await service.requestDeletion(ownerID: "owner-a")
        let requests = await api.requests()

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.ownerID, "owner-a")
        XCTAssertEqual(requests.first?.receiptToken, pending.receiptToken)
        XCTAssertEqual(journal.value, pending)
    }

    @MainActor
    func testLostDeleteResponseCompletesOnlyWithConfirmedReceipt() async throws {
        let journal = MemoryAccountDeletionJournal()
        let api = MockAccountDeletionAPI(requestResult: .failure, receiptResult: .confirmed)
        let service = AccountDeletionRecoveryService(api: api, journal: journal)

        let pending = try await service.requestDeletion(ownerID: "owner-a")

        XCTAssertEqual(journal.value, pending)
    }

    @MainActor
    func testUnconfirmedLostResponsePreservesReceiptForExactRetry() async {
        for receiptResult in [
            MockAccountDeletionAPI.ReceiptResult.unconfirmed,
            .unavailable,
        ] {
            let journal = MemoryAccountDeletionJournal()
            let api = MockAccountDeletionAPI(requestResult: .failure, receiptResult: receiptResult)
            let service = AccountDeletionRecoveryService(api: api, journal: journal)

            do {
                _ = try await service.requestDeletion(ownerID: "owner-a")
                XCTFail("unconfirmed deletion must not succeed")
            } catch {
                XCTAssertEqual(error as? AccountDeletionRecoveryError, .couldNotConfirm)
            }
            XCTAssertEqual(journal.value?.ownerID, "owner-a")
        }
    }

    @MainActor
    func testRejectedDeleteWithAbsentReceiptRemovesReplayJournal() async {
        let journal = MemoryAccountDeletionJournal()
        let api = MockAccountDeletionAPI(
            requestResult: .definitiveHTTPFailure,
            receiptResult: .unconfirmed
        )
        let service = AccountDeletionRecoveryService(api: api, journal: journal)

        do {
            _ = try await service.requestDeletion(ownerID: "owner-a")
            XCTFail("rejected deletion must not succeed")
        } catch {
            XCTAssertEqual(error as? AccountDeletionRecoveryError, .couldNotConfirm)
        }

        XCTAssertNil(journal.value)
    }

    @MainActor
    func testRejectedDeleteWithUnavailableReceiptLookupPreservesJournal() async {
        let journal = MemoryAccountDeletionJournal()
        let api = MockAccountDeletionAPI(
            requestResult: .definitiveHTTPFailure,
            receiptResult: .unavailable
        )
        let service = AccountDeletionRecoveryService(api: api, journal: journal)

        do {
            _ = try await service.requestDeletion(ownerID: "owner-a")
            XCTFail("unconfirmed deletion must not succeed")
        } catch {
            XCTAssertEqual(error as? AccountDeletionRecoveryError, .couldNotConfirm)
        }

        XCTAssertEqual(journal.value?.ownerID, "owner-a")
    }

    @MainActor
    func testAmbiguousServerFailureWithAbsentReceiptPreservesJournal() async {
        let journal = MemoryAccountDeletionJournal()
        let api = MockAccountDeletionAPI(
            requestResult: .ambiguousHTTPFailure,
            receiptResult: .unconfirmed
        )
        let service = AccountDeletionRecoveryService(api: api, journal: journal)

        do {
            _ = try await service.requestDeletion(ownerID: "owner-a")
            XCTFail("ambiguous deletion must not succeed")
        } catch {
            XCTAssertEqual(error as? AccountDeletionRecoveryError, .couldNotConfirm)
        }

        XCTAssertEqual(journal.value?.ownerID, "owner-a")
    }

    @MainActor
    func testRelaunchRejectedRetryWithAbsentReceiptRemovesReplayJournal() async throws {
        let pending = PendingAccountDeletion(
            ownerID: "owner-a",
            receiptToken: "mta_del_" + String(repeating: "b", count: 43)
        )
        let journal = MemoryAccountDeletionJournal()
        journal.value = pending
        let service = AccountDeletionRecoveryService(
            api: MockAccountDeletionAPI(
                requestResult: .definitiveHTTPFailure,
                receiptResult: .unconfirmed
            ),
            journal: journal
        )

        let recovered = try await service.confirmedPendingDeletion(
            retryOwnerID: "owner-a"
        )

        XCTAssertNil(recovered)
        XCTAssertNil(journal.value)
    }

    @MainActor
    func testRelaunchAmbiguousServerFailurePreservesReplayJournal() async throws {
        let pending = PendingAccountDeletion(
            ownerID: "owner-a",
            receiptToken: "mta_del_" + String(repeating: "e", count: 43)
        )
        let journal = MemoryAccountDeletionJournal()
        journal.value = pending
        let service = AccountDeletionRecoveryService(
            api: MockAccountDeletionAPI(
                requestResult: .ambiguousHTTPFailure,
                receiptResult: .unconfirmed
            ),
            journal: journal
        )

        let recovered = try await service.confirmedPendingDeletion(
            retryOwnerID: "owner-a"
        )

        XCTAssertNil(recovered)
        XCTAssertEqual(journal.value, pending)
    }

    @MainActor
    func testRelaunchRecoveryPreservesFalseReceiptAndReturnsCommittedReceipt() async throws {
        let pending = PendingAccountDeletion(
            ownerID: "owner-a",
            receiptToken: "mta_del_" + String(repeating: "a", count: 43)
        )

        let falseJournal = MemoryAccountDeletionJournal()
        falseJournal.value = pending
        let falseService = AccountDeletionRecoveryService(
            api: MockAccountDeletionAPI(requestResult: .failure, receiptResult: .unconfirmed),
            journal: falseJournal
        )
        let falseResult = try await falseService.confirmedPendingDeletion()
        XCTAssertNil(falseResult)
        XCTAssertEqual(falseJournal.value, pending)

        let trueJournal = MemoryAccountDeletionJournal()
        trueJournal.value = pending
        let trueService = AccountDeletionRecoveryService(
            api: MockAccountDeletionAPI(requestResult: .failure, receiptResult: .confirmed),
            journal: trueJournal
        )
        let trueResult = try await trueService.confirmedPendingDeletion()
        XCTAssertEqual(trueResult, pending)
        XCTAssertEqual(trueJournal.value, pending)
    }

    @MainActor
    func testRelaunchRetriesExactPreparedReceiptOnlyForTheSameOwner() async throws {
        let pending = PendingAccountDeletion(
            ownerID: "owner-a",
            receiptToken: "mta_del_" + String(repeating: "c", count: 43)
        )
        let journal = MemoryAccountDeletionJournal()
        journal.value = pending
        let api = MockAccountDeletionAPI(requestResult: .success, receiptResult: .unconfirmed)
        let service = AccountDeletionRecoveryService(api: api, journal: journal)

        let wrongOwnerResult = try await service.confirmedPendingDeletion(retryOwnerID: "owner-b")
        XCTAssertNil(wrongOwnerResult)
        let requestsBeforeRetry = await api.requests()
        XCTAssertTrue(requestsBeforeRetry.isEmpty)

        let recovered = try await service.confirmedPendingDeletion(retryOwnerID: "owner-a")
        XCTAssertEqual(recovered, pending)
        let requests = await api.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.receiptToken, pending.receiptToken)
    }

    // MARK: - Launch resolution

    private struct LaunchHarness {
        let service: AccountDeletionRecoveryService
        let journal: MemoryAccountDeletionJournal
        let deviceSession: DeviceSessionController
        let consent: AIProcessingConsentManager
        let shareKeys: ShareUploadKeyManager
        let cleaner: RecordingDeletionCleaner
        let defaults: UserDefaults
    }

    @MainActor
    private func launchHarness(
        pending: PendingAccountDeletion?,
        api: MockAccountDeletionAPI
    ) throws -> LaunchHarness {
        let pair = DeviceSessionPair(
            sessionID: "session-a",
            userID: "owner-a",
            accessToken: "mta_at_a",
            accessExpiresAt: Date().addingTimeInterval(3_600),
            refreshToken: "mta_rt_a",
            inactiveExpiresAt: Date().addingTimeInterval(86_400)
        )
        let deviceSession = DeviceSessionController(
            transport: DisabledSessionTransportForDeletionTests(),
            store: AccountDeletionDeviceSessionStore(StoredDeviceSession(pair: pair, source: .passkey))
        )
        let journal = MemoryAccountDeletionJournal()
        journal.value = pending
        let suiteName = "AccountDeletionRecoveryServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return LaunchHarness(
            service: AccountDeletionRecoveryService(api: api, journal: journal),
            journal: journal,
            deviceSession: deviceSession,
            consent: AIProcessingConsentManager(defaults: defaults),
            shareKeys: ShareUploadKeyManager(
                credentials: EmptyShareUploadCredentialStore(),
                api: UnusedShareUploadKeyAPI(),
                defaults: defaults
            ),
            cleaner: RecordingDeletionCleaner(),
            defaults: defaults
        )
    }

    @MainActor
    private func resolve(_ harness: LaunchHarness, retryOwnerID: String?) async -> AccountDeletionRecoveryService.PendingDeletionResolution {
        await harness.service.resolvePendingDeletion(
            retryOwnerID: retryOwnerID,
            uploadCoordinator: harness.cleaner,
            consent: harness.consent,
            deviceSession: harness.deviceSession,
            shareKeys: harness.shareKeys
        )
    }

    @MainActor
    func testALaunchLookupThatCannotAnswerKeepsTheWorkspaceClosed() async throws {
        let pending = PendingAccountDeletion(ownerID: "owner-a", receiptToken: "mta_del_" + String(repeating: "f", count: 43))
        let harness = try launchHarness(
            pending: pending,
            api: MockAccountDeletionAPI(requestResult: .failure, receiptResult: .unavailable)
        )

        let resolution = await resolve(harness, retryOwnerID: "owner-a")

        XCTAssertEqual(resolution, .unresolved)
        XCTAssertEqual(harness.journal.value, pending, "The journal stays for the next try")
        XCTAssertEqual(harness.deviceSession.storedUserID, "owner-a", "The owner is never signed out by a lookup that failed")
        XCTAssertTrue(harness.cleaner.removedOwners.isEmpty, "No recording is removed without a confirmed deletion")
    }

    @MainActor
    func testAnUnprovenRetryForTheSignedInOwnerKeepsTheWorkspaceClosed() async throws {
        let pending = PendingAccountDeletion(ownerID: "owner-a", receiptToken: "mta_del_" + String(repeating: "g", count: 43))
        let harness = try launchHarness(
            pending: pending,
            api: MockAccountDeletionAPI(requestResult: .ambiguousHTTPFailure, receiptResult: .unconfirmed)
        )

        let resolution = await resolve(harness, retryOwnerID: "owner-a")

        XCTAssertEqual(resolution, .unresolved)
        XCTAssertEqual(harness.journal.value, pending)
        XCTAssertEqual(harness.deviceSession.storedUserID, "owner-a")
    }

    @MainActor
    func testAJournalForAnotherAccountDoesNotBlockThisOne() async throws {
        let pending = PendingAccountDeletion(ownerID: "owner-b", receiptToken: "mta_del_" + String(repeating: "h", count: 43))
        let harness = try launchHarness(
            pending: pending,
            api: MockAccountDeletionAPI(requestResult: .failure, receiptResult: .unconfirmed)
        )

        let resolution = await resolve(harness, retryOwnerID: "owner-a")

        XCTAssertEqual(resolution, .none)
        XCTAssertEqual(harness.journal.value, pending)
    }

    @MainActor
    func testNoJournalNeedsNoNetworkAndOpensTheWorkspace() async throws {
        let harness = try launchHarness(
            pending: nil,
            api: MockAccountDeletionAPI(requestResult: .failure, receiptResult: .unavailable)
        )
        let resolution = await resolve(harness, retryOwnerID: "owner-a")
        XCTAssertEqual(resolution, .none)
    }

    @MainActor
    func testARejectedDeleteWithNoReceiptOpensTheWorkspaceAgain() async throws {
        let pending = PendingAccountDeletion(ownerID: "owner-a", receiptToken: "mta_del_" + String(repeating: "i", count: 43))
        let harness = try launchHarness(
            pending: pending,
            api: MockAccountDeletionAPI(requestResult: .definitiveHTTPFailure, receiptResult: .unconfirmed)
        )

        let resolution = await resolve(harness, retryOwnerID: "owner-a")

        XCTAssertEqual(resolution, .none)
        XCTAssertNil(harness.journal.value)
        XCTAssertEqual(harness.deviceSession.storedUserID, "owner-a")
    }

    @MainActor
    func testAConfirmedDeletionIsFinishedAndClosesTheAccount() async throws {
        let pending = PendingAccountDeletion(ownerID: "owner-a", receiptToken: "mta_del_" + String(repeating: "j", count: 43))
        let harness = try launchHarness(
            pending: pending,
            api: MockAccountDeletionAPI(requestResult: .success, receiptResult: .confirmed)
        )

        let resolution = await resolve(harness, retryOwnerID: "owner-a")

        XCTAssertEqual(resolution, .completed)
        XCTAssertNil(harness.journal.value)
        XCTAssertEqual(harness.cleaner.removedOwners, ["owner-a"])
        XCTAssertNil(harness.deviceSession.storedUserID)
    }

    @MainActor
    func testAccountSwitchDuringLocalCleanupPreservesNewDeviceSession() async throws {
        func pair(ownerID: String, sessionID: String) -> DeviceSessionPair {
            DeviceSessionPair(
                sessionID: sessionID,
                userID: ownerID,
                accessToken: "mta_at_" + ownerID,
                accessExpiresAt: Date().addingTimeInterval(3_600),
                refreshToken: "mta_rt_" + ownerID,
                inactiveExpiresAt: Date().addingTimeInterval(86_400)
            )
        }
        let ownerA = pair(ownerID: "owner-a", sessionID: "session-a")
        let ownerB = pair(ownerID: "owner-b", sessionID: "session-b")
        let store = AccountDeletionDeviceSessionStore(
            StoredDeviceSession(pair: ownerA, source: .passkey)
        )
        let deviceSession = DeviceSessionController(
            transport: DisabledSessionTransportForDeletionTests(),
            store: store
        )
        try deviceSession.saveSession(pair: ownerA, source: .passkey)

        let pending = PendingAccountDeletion(
            ownerID: "owner-a",
            receiptToken: "mta_del_" + String(repeating: "d", count: 43)
        )
        let journal = MemoryAccountDeletionJournal()
        journal.value = pending
        let service = AccountDeletionRecoveryService(
            api: MockAccountDeletionAPI(requestResult: .success, receiptResult: .confirmed),
            journal: journal
        )
        let cleaner = AccountSwitchingDeletionCleaner {
            deviceSession.clear()
            try! deviceSession.saveSession(pair: ownerB, source: .passkey)
        }
        let suiteName = "AccountDeletionRecoveryServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try await service.finishLocalDeletion(
            pending,
            uploadCoordinator: cleaner,
            consent: AIProcessingConsentManager(defaults: defaults),
            deviceSession: deviceSession,
            shareKeys: ShareUploadKeyManager(
                credentials: EmptyShareUploadCredentialStore(),
                api: UnusedShareUploadKeyAPI(),
                defaults: defaults
            )
        )

        XCTAssertEqual(deviceSession.storedUserID, "owner-b")
        XCTAssertEqual(deviceSession.activeUserID, "owner-b")
        XCTAssertNil(journal.value)
    }
}

private actor DisabledSessionTransportForDeletionTests: DeviceSessionTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

private struct EmptyShareUploadCredentialStore: ShareUploadCredentialStoring {
    func load() -> ShareUploadCredentialLoadResult { .missing }
    func save(_ credential: ShareUploadCredential) throws {}
    func delete() {}
    func delete(ifKeyID keyID: String) {}
}

private struct UnusedShareUploadKeyAPI: ShareUploadKeyAPI {
    func createShareUploadKey(name: String, ownerID: String) async throws -> ShareUploadKeyResponse {
        throw APIError.invalidResponse
    }
    func listAPIKeys(ownerID: String) async throws -> [ListedAPIKey] { [] }
    func listAPIKeys(bearerToken: String) async throws -> [ListedAPIKey] { [] }
    func revokeAPIKey(id: String, ownerID: String) async throws {}
    func revokeAPIKey(id: String, bearerToken: String) async throws {}
}

private struct PasswordRejectingDeletionAPI: AccountDeletionAPI {
    func requestAccountDeletion(ownerID: String, receiptToken: String, currentPassword: String?) async throws {
        throw APIError.httpError(statusCode: 401, code: "current_password_required", message: "Enter your current password")
    }
    func accountDeletionReceiptConfirmed(_ receiptToken: String) async throws -> Bool { false }
}
