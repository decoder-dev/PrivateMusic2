import XCTest
@testable import PrivateMusic

// `SessionStore.connect` requires a token of at least 16 characters, so
// these fixtures are deliberately longer than a minimal placeholder.
private let validAccessToken = "valid-access-token-0123456789"
private let staleAccessToken = "stale-access-token-0123456789"
private let refreshedAccessToken = "refreshed-access-token-0123456789"

@MainActor
final class HomeCatalogRefreshControllerTests: XCTestCase {
    private var keychainService: String!

    override func setUp() {
        super.setUp()
        keychainService = "pm-tests-home-catalog-\(UUID().uuidString)"
    }

    override func tearDown() {
        keychainService = nil
        super.tearDown()
    }

    // MARK: - Single request for the shared catalog endpoint

    func testCatalogSectionsIsRequestedExactlyOnceInARefresh() async {
        let (controller, sessionStore, store, service, _) = makeSubject()
        await connectSession(sessionStore, accessToken: validAccessToken)

        await controller.refreshHomeCatalog(force: true)

        let callCount = await service.catalogSectionsCallCount
        XCTAssertEqual(
            callCount,
            1,
            "mixes and new releases must be derived from one shared "
                + "catalog.getAudio-backed call, not one request per section"
        )
    }

    // MARK: - Independent sections start concurrently

    func testIndependentSectionsStartConcurrently() async {
        let timeline = Timeline()
        let (controller, sessionStore, store, service, _) = makeSubject()
        await connectSession(sessionStore, accessToken: validAccessToken)
        await service.update { configuration in
            configuration.recommendations = {
                await timeline.record("recommendations")
                try? await Task.sleep(for: .milliseconds(150))
                return []
            }
            configuration.catalogSections = {
                await timeline.record("catalogSections")
                try? await Task.sleep(for: .milliseconds(150))
                return CatalogSections(mixes: [], newReleases: [])
            }
            configuration.playlists = {
                await timeline.record("playlists")
                try? await Task.sleep(for: .milliseconds(150))
                return MusicPage(items: [], totalCount: 0, nextOffset: nil)
            }
        }

        await controller.refreshHomeCatalog(force: true)

        let starts = await timeline.starts
        XCTAssertEqual(starts.count, 3)
        guard let earliest = starts.values.min(),
              let latest = starts.values.max() else {
            XCTFail("Expected all three sections to record a start time")
            return
        }
        // Each section sleeps 150ms after recording its start. If the
        // sections ran sequentially, later sections would start roughly a
        // multiple of 150ms after the first. A window well under that
        // proves they were all in flight together instead.
        XCTAssertLessThan(
            latest.timeIntervalSince(earliest),
            0.075,
            "independent sections should start close together in time, "
                + "not one after another"
        )
    }

    // MARK: - Partial failure preserves successful sections

    func testPartialFailurePreservesSuccessfulSections() async {
        let (controller, sessionStore, store, service, _) = makeSubject()
        await connectSession(sessionStore, accessToken: validAccessToken)
        let recommendation = makeTrack(id: 1)
        let playlist = Playlist(
            id: 10,
            ownerID: -1,
            title: "Playlist",
            description: nil,
            count: 0,
            artworkURL: nil,
            accessKey: nil
        )
        await service.update { configuration in
            configuration.recommendations = { [recommendation] }
            configuration.catalogSections = {
                throw APIError.transport("boom")
            }
            configuration.playlists = {
                MusicPage(items: [playlist], totalCount: 1, nextOffset: nil)
            }
        }

        await controller.refreshHomeCatalog(force: true)

        XCTAssertEqual(store.recommendations.map(\.id), [recommendation.id])
        XCTAssertEqual(store.playlists.map(\.id), [playlist.id])
        XCTAssertTrue(
            store.mixes.isEmpty,
            "a failed catalog-sections fetch must not fabricate mixes"
        )
        XCTAssertEqual(
            store.newReleases,
            [],
            "the speculative new-releases shelf stays hidden, not errored"
        )
        XCTAssertNotNil(
            store.errorMessage,
            "the shared catalog-sections failure is still a real error"
        )
    }

    // MARK: - Cancellation leaves state untouched

    func testCancelledRefreshDoesNotChangeState() async {
        let (controller, sessionStore, store, service, _) = makeSubject()
        await connectSession(sessionStore, accessToken: validAccessToken)
        await service.update { configuration in
            configuration.recommendations = {
                try await Task.sleep(for: .seconds(30))
                return []
            }
            configuration.catalogSections = {
                try await Task.sleep(for: .seconds(30))
                return CatalogSections(mixes: [], newReleases: [])
            }
            configuration.playlists = {
                try await Task.sleep(for: .seconds(30))
                return MusicPage(items: [], totalCount: 0, nextOffset: nil)
            }
        }

        let task = Task {
            await controller.refreshHomeCatalog(force: true)
        }
        // Give the refresh a moment to start (and begin marking itself as
        // refreshing) before cancelling it.
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await task.value

        XCTAssertFalse(store.isRefreshing)
        XCTAssertTrue(store.recommendations.isEmpty)
        XCTAssertTrue(store.mixes.isEmpty)
        XCTAssertTrue(store.playlists.isEmpty)
        XCTAssertTrue(store.newReleases.isEmpty)
        XCTAssertNil(store.lastRefreshedAt)
    }

    // MARK: - A superseded (stale) refresh does not clobber newer state

    func testStaleRefreshDoesNotOverwriteNewerState() async {
        let (controller, sessionStore, store, service, _) = makeSubject()
        await connectSession(sessionStore, accessToken: validAccessToken)

        let staleTrack = makeTrack(id: 1)
        let gate = Gate()

        // Gated so the in-flight refresh only finishes after the account
        // has switched underneath it (e.g. logout/login to a different
        // account while the first account's refresh was still loading).
        await service.update { configuration in
            configuration.recommendations = {
                await gate.waitUntilOpen()
                return [staleTrack]
            }
        }
        let staleTask = Task {
            await controller.refreshHomeCatalog(force: true)
        }
        // Let the refresh actually begin (call beginRefreshing() and start
        // its async-let sections) before switching accounts underneath it.
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(store.isRefreshing)

        // Simulates what `AppEnvironment.configureOfflineAccount()` +
        // a fresh `refreshHomeCatalog()` do on an account switch: prepare()
        // bumps the store's refresh generation and resets its state.
        store.prepare(accountID: 999)
        XCTAssertFalse(store.isRefreshing)

        // Only now let the superseded refresh's in-flight call resolve.
        await gate.open()
        await staleTask.value

        XCTAssertTrue(
            store.recommendations.isEmpty,
            "a refresh superseded by an account switch must not write its "
                + "stale result into the new account's state"
        )
        XCTAssertFalse(store.isRefreshing)
    }

    // MARK: - Unauthorized coalesces into one session recovery

    func testUnauthorizedTriggersAtMostOneSessionRecovery() async {
        let (controller, sessionStore, store, service, webAuth) = makeSubject()
        await connectSession(
            sessionStore,
            accessToken: staleAccessToken,
            refreshCookie: "session=abc",
            webUserAgent: "TestAgent/1.0"
        )
        let refreshedProfile = UserProfile(
            id: 7,
            firstName: "A",
            lastName: "B",
            photoURL: nil
        )
        await webAuth.configure(
            result: VKWebAuthResult(
                accessToken: refreshedAccessToken,
                userID: 7,
                expiresAt: nil,
                apiUserAgent: "RefreshedAgent/1.0",
                refreshCookie: "session=abc",
                webUserAgent: "TestAgent/1.0"
            ),
            delayMilliseconds: 30
        )
        await service.update { configuration in
            configuration.profile = { refreshedProfile }
            // Every gated call fails with `.unauthorized` until it is
            // retried with the token the (single) web-token exchange
            // produced — see `FakeMusicService.validateToken`.
            configuration.tokenGate = refreshedAccessToken
        }

        await controller.refreshHomeCatalog(force: true)

        let exchangeCallCount = await webAuth.exchangeCallCount
        XCTAssertEqual(
            exchangeCallCount,
            1,
            "three sections hitting 401 at once must still only trigger "
                + "one web-token exchange"
        )
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.recommendations, [])
    }

    // MARK: - Helpers

    private func makeSubject() -> (
        HomeCatalogRefreshController,
        SessionStore,
        HomeCatalogStore,
        FakeMusicService,
        FakeWebAuthExchanger
    ) {
        let keychain = KeychainStore(service: keychainService)
        let sessionStore = SessionStore(keychain: keychain)
        let homeCatalogStore = HomeCatalogStore()
        let service = FakeMusicService()
        let webAuth = FakeWebAuthExchanger()
        let controller = HomeCatalogRefreshController(
            sessionStore: sessionStore,
            musicService: service,
            webAuthService: webAuth,
            homeCatalogStore: homeCatalogStore,
            onUserAgentChanged: { _ in }
        )
        return (controller, sessionStore, homeCatalogStore, service, webAuth)
    }

    private func connectSession(
        _ sessionStore: SessionStore,
        accessToken: String,
        refreshCookie: String? = nil,
        webUserAgent: String? = nil
    ) async {
        try? sessionStore.connect(
            accessToken: accessToken,
            userAgent: nil,
            refreshCookie: refreshCookie,
            webUserAgent: webUserAgent,
            profile: UserProfile(
                id: 1,
                firstName: "First",
                lastName: "Last",
                photoURL: nil
            )
        )
    }

    private func makeTrack(id: Int) -> Track {
        Track(
            trackID: id,
            ownerID: -1,
            title: "Track \(id)",
            artist: "Artist",
            duration: 120,
            streamURL: URL(string: "https://example.com/\(id).mp3"),
            artworkURL: nil
        )
    }
}

private actor Timeline {
    private(set) var starts: [String: Date] = [:]

    func record(_ name: String) {
        starts[name] = Date()
    }
}

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func waitUntilOpen() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

/// Minimal `MusicService` fake. Only the members exercised by
/// `HomeCatalogRefreshController` are configurable; everything else returns
/// an empty/neutral value since these tests never touch it.
private actor FakeMusicService: MusicService {
    struct Configuration: Sendable {
        var recommendations: @Sendable () async throws -> [Track] = { [] }
        var catalogSections: @Sendable () async throws -> CatalogSections = {
            CatalogSections(mixes: [], newReleases: [])
        }
        var playlists: @Sendable () async throws -> MusicPage<Playlist> = {
            MusicPage(items: [], totalCount: 0, nextOffset: nil)
        }
        var profile: @Sendable () async throws -> UserProfile = {
            UserProfile(id: 1, firstName: "A", lastName: "B", photoURL: nil)
        }
        /// When set, `recommendations`/`catalogSections`/`playlists` throw
        /// `.unauthorized` unless called with exactly this token — used to
        /// simulate a stale token that only a session recovery clears.
        var tokenGate: String?
    }

    private var configuration = Configuration()
    private(set) var recommendationsCallCount = 0
    private(set) var catalogSectionsCallCount = 0
    private(set) var playlistsCallCount = 0
    private(set) var lastAttemptedToken: String?

    func update(_ body: (inout Configuration) -> Void) {
        body(&configuration)
    }

    private func validateToken(_ token: String) throws {
        if let gate = configuration.tokenGate, token != gate {
            throw APIError.unauthorized
        }
    }

    func configure(userAgent: String?) async {}

    func profile(accessToken: String) async throws -> UserProfile {
        try await configuration.profile()
    }

    func library(
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Track> {
        MusicPage(items: [], totalCount: 0, nextOffset: nil)
    }

    func recommendations(accessToken: String) async throws -> [Track] {
        lastAttemptedToken = accessToken
        recommendationsCallCount += 1
        try validateToken(accessToken)
        return try await configuration.recommendations()
    }

    func refreshedTrack(
        _ track: Track,
        accessToken: String
    ) async throws -> Track {
        track
    }

    func mixes(accessToken: String) async throws -> [MusicMix] { [] }

    func catalogSections(
        accessToken: String
    ) async throws -> CatalogSections {
        lastAttemptedToken = accessToken
        catalogSectionsCallCount += 1
        try validateToken(accessToken)
        return try await configuration.catalogSections()
    }

    func mixTracks(
        _ mix: MusicMix,
        accessToken: String
    ) async throws -> [Track] {
        []
    }

    func search(
        query: String,
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Track> {
        MusicPage(items: [], totalCount: 0, nextOffset: nil)
    }

    func searchAlbums(
        query: String,
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Album> {
        MusicPage(items: [], totalCount: 0, nextOffset: nil)
    }

    func likedAlbums(
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Album> {
        MusicPage(items: [], totalCount: 0, nextOffset: nil)
    }

    func albumTracks(
        _ album: Album,
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Track> {
        MusicPage(items: [], totalCount: 0, nextOffset: nil)
    }

    func toggleAlbumFollow(
        _ album: Album,
        follow: Bool,
        accessToken: String
    ) async throws {}

    func playlists(
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Playlist> {
        lastAttemptedToken = accessToken
        playlistsCallCount += 1
        try validateToken(accessToken)
        return try await configuration.playlists()
    }

    func playlistTracks(
        _ playlist: Playlist,
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Track> {
        MusicPage(items: [], totalCount: 0, nextOffset: nil)
    }

    func addToLibrary(
        _ track: Track,
        accessToken: String
    ) async throws -> Track {
        track
    }

    func removeFromLibrary(
        _ track: Track,
        accessToken: String
    ) async throws {}

    func lyrics(
        for track: Track,
        accessToken: String
    ) async throws -> Lyrics {
        Lyrics(text: "", source: "test")
    }

    func createPlaylist(
        title: String,
        description: String,
        ownerID: Int,
        accessToken: String
    ) async throws -> Playlist {
        Playlist(
            id: 0,
            ownerID: ownerID,
            title: title,
            description: description,
            count: 0,
            artworkURL: nil,
            accessKey: nil
        )
    }

    func editPlaylist(
        _ playlist: Playlist,
        title: String,
        description: String,
        accessToken: String
    ) async throws {}

    func deletePlaylist(
        _ playlist: Playlist,
        accessToken: String
    ) async throws {}

    func add(
        _ track: Track,
        to playlist: Playlist,
        accessToken: String
    ) async throws {}

    func remove(
        _ track: Track,
        from playlist: Playlist,
        accessToken: String
    ) async throws {}
}

private actor FakeWebAuthExchanger: VKWebAuthExchanging {
    private(set) var exchangeCallCount = 0
    private var result: VKWebAuthResult?
    private var delayMilliseconds: UInt64 = 0

    func configure(result: VKWebAuthResult, delayMilliseconds: Int = 0) {
        self.result = result
        self.delayMilliseconds = UInt64(delayMilliseconds)
    }

    func exchange(
        cookieHeader: String,
        webUserAgent: String
    ) async throws -> VKWebAuthResult {
        exchangeCallCount += 1
        if delayMilliseconds > 0 {
            try? await Task.sleep(
                for: .milliseconds(delayMilliseconds)
            )
        }
        guard let result else { throw VKWebAuthError.noSession }
        return result
    }
}
