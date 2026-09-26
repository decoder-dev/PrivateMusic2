import XCTest
@testable import PrivateMusic

@MainActor
final class AccountIsolationTests: XCTestCase {
    private func store() -> SessionStore {
        SessionStore(keychain: MemoryKeychainStore())
    }

    private func connect(_ store: SessionStore, user: Int, token: String) throws {
        try store.connect(
            accessToken: token,
            userAgent: nil,
            profile: UserProfile(id: user, firstName: "Test", lastName: "", photoURL: nil)
        )
    }

    func testSessionRestoresFromInjectedStorageAndLogoutRemovesIt() throws {
        let storage = MemoryKeychainStore()
        let session = SessionStore(keychain: storage)
        try connect(session, user: 1, token: "aaaaaaaaaaaaaaaa")

        let restored = SessionStore(keychain: storage)
        XCTAssertEqual(restored.accessToken, "aaaaaaaaaaaaaaaa")
        XCTAssertEqual(restored.resolvedOfflineAccountID, 1)
        restored.logout()

        let afterLogout = SessionStore(keychain: storage)
        XCTAssertNil(afterLogout.session)
        XCTAssertNil(afterLogout.profile)
    }

    func testTokenRotationKeepsAccountGenerationButLogoutDoesNot() throws {
        let session = store()
        defer { session.logout() }
        try connect(session, user: 1, token: "aaaaaaaaaaaaaaaa")
        let first = session.accountRevision
        try connect(session, user: 1, token: "bbbbbbbbbbbbbbbb")
        XCTAssertEqual(session.accountRevision, first)
        session.logout()
        try connect(session, user: 1, token: "cccccccccccccccc")
        XCTAssertNotEqual(session.accountRevision, first)
    }

    func testRejectedOldAccountOperationIsNeverRetriedForNewAccount() async throws {
        let session = store()
        defer { session.logout() }
        try connect(session, user: 1, token: "aaaaaaaaaaaaaaaa")
        var attempted: [String] = []
        do {
            let _: String = try await session.withAuthorizedToken(recoverSession: {
                XCTFail("Account switch must not start recovery")
                throw APIError.unauthorized
            }) { token in
                attempted.append(token)
                try self.connect(session, user: 2, token: "bbbbbbbbbbbbbbbb")
                throw APIError.unauthorized
            }
            XCTFail("Old operation must be cancelled")
        } catch is CancellationError {
            XCTAssertEqual(attempted, ["aaaaaaaaaaaaaaaa"])
        }
    }

    func testSuccessfulOldAccountResponseIsDiscarded() async throws {
        let session = store()
        defer { session.logout() }
        try connect(session, user: 1, token: "aaaaaaaaaaaaaaaa")
        do {
            let _: String = try await session.withAuthorizedToken(recoverSession: {
                throw APIError.unauthorized
            }) { _ in
                session.logout()
                // Even the same user logging in again is a new session boundary.
                try self.connect(session, user: 1, token: "bbbbbbbbbbbbbbbb")
                return "stale library"
            }
            XCTFail("Result from before logout must not be applied")
        } catch is CancellationError {}
    }

    func testRejectedTokenCanRetryAfterRotationWithinTheSameAccount() async throws {
        let session = store()
        defer { session.logout() }
        try connect(session, user: 1, token: "aaaaaaaaaaaaaaaa")
        var attempted: [String] = []
        let result = try await session.withAuthorizedToken(recoverSession: {
            XCTFail("The latest token already exists")
            throw APIError.unauthorized
        }) { token in
            attempted.append(token)
            if attempted.count == 1 {
                try self.connect(session, user: 1, token: "bbbbbbbbbbbbbbbb")
                throw APIError.unauthorized
            }
            return "fresh"
        }
        XCTAssertEqual(result, "fresh")
        XCTAssertEqual(attempted, ["aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb"])
    }

    func testAccountChangeNotifiesAfterTheNewIdentityIsVisible() throws {
        let session = store()
        defer { session.logout() }
        var accounts: [Int?] = []
        session.onAccountChange = { accounts.append(session.resolvedOfflineAccountID) }
        defer { session.onAccountChange = nil }
        try connect(session, user: 1, token: "aaaaaaaaaaaaaaaa")
        try connect(session, user: 1, token: "bbbbbbbbbbbbbbbb")
        try connect(session, user: 2, token: "cccccccccccccccc")
        session.logout()
        XCTAssertEqual(accounts, [1, 2, nil])
    }

    func testFailedRecoveryAfterAccountChangeIsCancellation() async throws {
        let session = store()
        defer { session.logout() }
        try connect(session, user: 1, token: "aaaaaaaaaaaaaaaa")
        do {
            let _: String = try await session.withAuthorizedToken(recoverSession: {
                try self.connect(session, user: 2, token: "bbbbbbbbbbbbbbbb")
                throw APIError.timedOut
            }) { _ in
                throw APIError.unauthorized
            }
            XCTFail("Recovery for an old account must not finish in the new one")
        } catch is CancellationError {}
    }

    func testMusicContextNeverReturnsAnotherTokensOwner() async {
        let context = VKMusicContext(userID: 1, accessToken: "A")
        let first = await context.userID(for: "A")
        let second = await context.userID(for: "B")
        XCTAssertEqual(first, 1)
        XCTAssertNil(second)
        await context.setUserID(2, accessToken: "B")
        // A late profile response must not resolve B as user 1.
        await context.setUserID(1, accessToken: "A")
        let afterLateResponse = await context.userID(for: "B")
        XCTAssertNil(afterLateResponse)
    }
}

/// Each test owns its storage; unsigned simulator tests never touch Keychain.
private final class MemoryKeychainStore: KeychainStoring {
    private var values: [String: Data] = [:]

    func save<Value: Codable>(_ value: Value, account: String) throws {
        values[account] = try JSONEncoder().encode(value)
    }

    func load<Value: Codable>(_ type: Value.Type, account: String) throws -> Value? {
        guard let data = values[account] else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }

    func delete(account: String) throws {
        values.removeValue(forKey: account)
    }
}
