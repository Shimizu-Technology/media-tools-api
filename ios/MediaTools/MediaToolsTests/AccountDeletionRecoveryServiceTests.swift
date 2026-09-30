import ClerkKit
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
        case httpFailure
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

    func requestAccountDeletion(ownerID: String, receiptToken: String) async throws {
        requested.append((ownerID, receiptToken))
        switch requestResult {
        case .success:
            return
        case .failure:
            throw URLError(.timedOut)
        case .httpFailure:
            throw APIError.httpError(
                statusCode: 503,
                code: "account_deletion_unavailable",
                message: "Account deletion is unavailable"
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
    func loadPendingBootstrap() throws -> PendingDeviceSessionBootstrap? { nil }
    func savePendingBootstrap(_ value: PendingDeviceSessionBootstrap) throws {}
    func deletePendingBootstrap() {}
    func localOwnerID(for clerkID: String) -> String? { mappings[clerkID] }
    func clerkID(forLocalOwnerID ownerID: String) -> String? {
        mappings.first(where: { $0.value == ownerID })?.key
    }
    func saveLocalOwnerID(_ ownerID: String, for clerkID: String) { mappings[clerkID] = ownerID }
    func removeLocalOwnerID(for clerkID: String) { mappings.removeValue(forKey: clerkID) }
}

final class AccountDeletionRecoveryServiceTests: XCTestCase {
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
            requestResult: .httpFailure,
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
            requestResult: .httpFailure,
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
    func testRelaunchRejectedRetryWithAbsentReceiptRemovesReplayJournal() async throws {
        let pending = PendingAccountDeletion(
            ownerID: "owner-a",
            receiptToken: "mta_del_" + String(repeating: "b", count: 43)
        )
        let journal = MemoryAccountDeletionJournal()
        journal.value = pending
        let service = AccountDeletionRecoveryService(
            api: MockAccountDeletionAPI(
                requestResult: .httpFailure,
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
            store: store,
            enabled: true
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
            tokenSync: TokenSyncService(),
            clerk: Clerk.shared
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
