import XCTest
@testable import PrivateMusic

@MainActor
final class OfflineTrackStoreTests: XCTestCase {
    func testDownloadPersistsAndRestoresForSameAccount() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeDownloadService()
        let store = OfflineTrackStore(
            rootURL: root,
            downloadService: service
        )
        let track = makeTrack()
        store.configure(accountID: 42)

        try await store.download(track, userAgent: "PrivateMusicTests")

        XCTAssertTrue(store.contains(track))
        XCTAssertEqual(store.downloadedTracks.map(\.id), [track.id])
        XCTAssertGreaterThan(store.totalByteCount, 0)

        let restored = OfflineTrackStore(
            rootURL: root,
            downloadService: service
        )
        restored.configure(accountID: 42)
        XCTAssertTrue(restored.contains(track))
        XCTAssertNotNil(restored.localURL(for: track))
    }

    func testAccountsAreIsolatedAndRemovalDeletesFile() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfflineTrackStore(
            rootURL: root,
            downloadService: makeDownloadService()
        )
        let track = makeTrack()
        store.configure(accountID: 42)
        try await store.download(track, userAgent: nil)
        let localURL = try XCTUnwrap(store.localURL(for: track))

        store.configure(accountID: 7)
        XCTAssertFalse(store.contains(track))

        store.configure(accountID: 42)
        store.remove(track)
        XCTAssertFalse(store.contains(track))
        XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
    }

    func testLegacyManifestDefaultsToDirectFileStorage() throws {
        let json = """
        [{
          "track": {
            "id": 7,
            "owner_id": -42,
            "title": "Title",
            "artist": "Artist",
            "duration": 120
          },
          "relativePath": "tracks/-42_7/audio.mp3",
          "byteCount": 8,
          "downloadedAt": "2026-07-30T12:00:00Z",
          "lastPlayedAt": "2026-07-30T12:00:00Z"
        }]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let records = try decoder.decode(
            [OfflineTrackRecord].self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(records.first?.resolvedStorage, .directFile)
        XCTAssertEqual(records.first?.resolvedRetention, .manual)
    }

    func testAutomaticCacheCanBePromotedAndClearedSafely() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfflineTrackStore(
            rootURL: root,
            downloadService: makeDownloadService()
        )
        let cached = makeTrack()
        let manual = Track(
            trackID: 8,
            ownerID: -42,
            title: "Manual",
            artist: "Artist",
            duration: 120,
            streamURL: URL(string: "https://example.com/manual.mp3"),
            artworkURL: nil
        )
        store.configure(accountID: 42)

        try await store.download(
            cached,
            userAgent: nil,
            retention: .automaticCache
        )
        try await store.download(manual, userAgent: nil)
        XCTAssertGreaterThan(store.automaticCacheByteCount, 0)

        try await store.download(cached, userAgent: nil)
        XCTAssertEqual(
            store.records[cached.id]?.resolvedRetention,
            .manual
        )

        store.removeAutomaticCache()
        XCTAssertTrue(store.contains(cached))
        XCTAssertTrue(store.contains(manual))
        XCTAssertEqual(store.automaticCacheByteCount, 0)
    }

    func testStorageLimitIsClampedToSupportedRange() {
        let store = OfflineTrackStore(rootURL: temporaryRoot())

        store.configureStorage(limitGB: 1)
        XCTAssertEqual(store.storageLimitBytes, 5_000_000_000)

        store.configureStorage(limitGB: 120)
        XCTAssertEqual(store.storageLimitBytes, 100_000_000_000)
    }

    func testReconcileDropsMissingFilesAndRemovesOrphans() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfflineTrackStore(
            rootURL: root,
            downloadService: makeDownloadService()
        )
        let track = makeTrack()
        store.configure(accountID: 42)
        try await store.download(track, userAgent: nil)

        let localURL = try XCTUnwrap(store.localURL(for: track))
        try FileManager.default.removeItem(at: localURL)

        let tracksDirectory = localURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tracks", isDirectory: true)
        let ghost = tracksDirectory.appendingPathComponent(
            "ghost-1",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: ghost,
            withIntermediateDirectories: true
        )
        try Data("ghost".utf8).write(
            to: ghost.appendingPathComponent("audio.mp3")
        )

        store.configure(accountID: 7)
        store.configure(accountID: 42)

        XCTAssertFalse(store.contains(track))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ghost.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tracksDirectory
                    .appendingPathComponent(track.id)
                    .path
            )
        )
    }

    func testDownloadedTrackCountReflectsActualFiles() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfflineTrackStore(
            rootURL: root,
            downloadService: makeDownloadService()
        )
        let first = makeTrack()
        let second = Track(
            trackID: 8,
            ownerID: -42,
            title: "Second",
            artist: "Artist",
            duration: 120,
            streamURL: URL(string: "https://example.com/second.mp3"),
            artworkURL: nil
        )
        store.configure(accountID: 42)
        try await store.download(first, userAgent: nil)
        try await store.download(second, userAgent: nil)
        XCTAssertEqual(store.downloadedTrackCount, 2)

        let localURL = try XCTUnwrap(store.localURL(for: first))
        try FileManager.default.removeItem(at: localURL)
        XCTAssertEqual(store.downloadedTrackCount, 1)
    }

    func testManualAndCacheCountsAndByteTotalsUseValidFiles() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfflineTrackStore(
            rootURL: root,
            downloadService: makeDownloadService()
        )
        let manual = makeTrack()
        let cached = Track(
            trackID: 8,
            ownerID: -42,
            title: "Cached",
            artist: "Artist",
            duration: 120,
            streamURL: URL(string: "https://example.com/cached.mp3"),
            artworkURL: nil
        )
        store.configure(accountID: 42)
        try await store.download(manual, userAgent: nil)
        try await store.download(
            cached,
            userAgent: nil,
            retention: .automaticCache
        )

        var usage = store.storageUsage
        XCTAssertEqual(usage.totalCount, 2)
        XCTAssertEqual(usage.manualCount, 1)
        XCTAssertEqual(usage.automaticCount, 1)
        XCTAssertGreaterThan(usage.manualBytes, 0)
        XCTAssertGreaterThan(usage.automaticBytes, 0)
        XCTAssertEqual(
            usage.audioBytes,
            usage.manualBytes + usage.automaticBytes
        )

        let cachedURL = try XCTUnwrap(store.localURL(for: cached))
        try FileManager.default.removeItem(at: cachedURL)
        usage = store.storageUsage
        XCTAssertEqual(usage.totalCount, 1)
        XCTAssertEqual(usage.manualCount, 1)
        XCTAssertEqual(usage.automaticCount, 0)
        XCTAssertGreaterThan(usage.manualBytes, 0)
        XCTAssertEqual(usage.automaticBytes, 0)
    }

    func testConcurrentDownloadsOfSameTrackDownloadOnce() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfflineTrackStore(
            rootURL: root,
            downloadService: makeDownloadService(),
            downloadCoordinator: DownloadCoordinator()
        )
        let track = makeTrack()
        store.configure(accountID: 42)

        async let first: Void = store.download(track, userAgent: nil)
        async let second: Void = store.download(track, userAgent: nil)
        _ = try await (first, second)

        XCTAssertTrue(store.contains(track))
    }

    func testManualCallerPromotesJoinedAutomaticCacheDownload() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let responseStarted = expectation(description: "response started")
        responseStarted.assertForOverFulfill = false
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineURLProtocol.self]
        OfflineURLProtocol.handler = { request in
            responseStarted.fulfill()
            Thread.sleep(forTimeInterval: 0.15)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "audio/mpeg",
                    "Content-Length": "8"
                ]
            )!
            return (response, Data("ID3audio".utf8))
        }
        let store = OfflineTrackStore(
            rootURL: root,
            downloadService: TrackShareService(
                session: URLSession(configuration: configuration)
            ),
            downloadCoordinator: DownloadCoordinator()
        )
        let track = makeTrack()
        store.configure(accountID: 42)

        let automatic = Task { @MainActor in
            try await store.download(
                track,
                userAgent: nil,
                retention: .automaticCache
            )
        }
        await fulfillment(of: [responseStarted], timeout: 1)
        let manual = Task { @MainActor in
            try await store.download(
                track,
                userAgent: nil,
                retention: .manual
            )
        }
        try await automatic.value
        try await manual.value

        XCTAssertEqual(
            store.record(for: track)?.resolvedRetention,
            .manual
        )
    }

    func testConfigureFlushesPendingActivityForPreviousAccount() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let track = makeTrack()
        let store = OfflineTrackStore(
            rootURL: root,
            downloadService: makeDownloadService(),
            downloadCoordinator: DownloadCoordinator()
        )
        store.configure(accountID: 1)
        try await store.download(track, userAgent: nil)
        store.markPlayed(track)

        store.configure(accountID: 2)

        let restored = OfflineTrackStore(
            rootURL: root,
            downloadService: makeDownloadService(),
            downloadCoordinator: DownloadCoordinator()
        )
        restored.configure(accountID: 1)
        XCTAssertEqual(restored.record(for: track)?.playCount, 1)
        XCTAssertTrue(restored.contains(track))
    }

    // MARK: - HLS integration (unified pipeline)

    func testHLSDownloadIsStoredAsDirectM4AFile() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfflineTrackStore(
            rootURL: root,
            downloadService: try makeHLSDownloadService(),
            downloadCoordinator: DownloadCoordinator()
        )
        let track = makeHLSTrack()
        store.configure(accountID: 42)

        try await store.download(track, userAgent: "PrivateMusicTests")

        XCTAssertTrue(store.contains(track))
        let record = try XCTUnwrap(store.records[track.id])
        XCTAssertEqual(record.resolvedStorage, .directFile)
        let localURL = try XCTUnwrap(store.localURL(for: track))
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path))
        XCTAssertEqual(localURL.pathExtension.lowercased(), "m4a")

        let restored = OfflineTrackStore(
            rootURL: root,
            downloadService: try makeHLSDownloadService()
        )
        restored.configure(accountID: 42)
        XCTAssertTrue(restored.contains(track))

        store.remove(track)
        XCTAssertFalse(store.contains(track))
        XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
    }

    func testCancelledHLSDownloadLeavesNoRecordsOrStaging() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try FragmentedMP4Fixture.make()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineURLProtocol.self]
        OfflineURLProtocol.handler = { request in
            if request.url?.lastPathComponent == "index.m3u8" {
                Thread.sleep(forTimeInterval: 0.5)
            }
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            switch request.url?.lastPathComponent {
            case "index.m3u8":
                return (response, Data(Self.hlsPlaylist.utf8))
            case "init.mp4":
                return (response, fixture.initialization)
            case "frag1.m4s":
                return (response, fixture.fragments[0])
            default:
                return (
                    response,
                    fixture.fragments.count > 1
                        ? fixture.fragments[1]
                        : fixture.fragments[0]
                )
            }
        }
        let coordinator = DownloadCoordinator()
        let store = OfflineTrackStore(
            rootURL: root,
            downloadService: TrackShareService(
                session: URLSession(configuration: configuration)
            ),
            downloadCoordinator: coordinator
        )
        store.configure(accountID: 42)

        let task = Task {
            try await store.download(makeHLSTrack(), userAgent: nil)
        }
        while store.downloadingTrackIDs.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        coordinator.cancelAll()
        _ = try? await task.value

        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(store.downloadedTrackCount, 0)
        let accountDirectory = root.appendingPathComponent(
            "42",
            isDirectory: true
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: accountDirectory
                    .appendingPathComponent("tracks", isDirectory: true)
                    .path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: accountDirectory
                    .appendingPathComponent(".staging", isDirectory: true)
                    .path
            )
        )
    }

    func testFailedHLSDownloadCreatesNoRecord() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineURLProtocol.self]
        OfflineURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 403,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        let store = OfflineTrackStore(
            rootURL: root,
            downloadService: TrackShareService(
                session: URLSession(configuration: configuration)
            ),
            downloadCoordinator: DownloadCoordinator()
        )
        store.configure(accountID: 42)

        do {
            try await store.download(makeHLSTrack(), userAgent: nil)
            XCTFail("A failed HLS download must throw")
        } catch {
            // Expected.
        }

        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(store.downloadedTrackCount, 0)
    }

    func testLegacyMovpkgRecordRemainsUsable() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfflineTrackStore(
            rootURL: root,
            downloadService: makeDownloadService()
        )
        let home = URL(
            fileURLWithPath: NSHomeDirectory(),
            isDirectory: true
        ).standardizedFileURL
        let packageURL = home
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent(
                "movpkg-\(UUID().uuidString).movpkg",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: packageURL,
            withIntermediateDirectories: true
        )
        try Data("legacy".utf8).write(
            to: packageURL.appendingPathComponent("media.movpkg")
        )
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let relativePath = packageURL.path.replacingOccurrences(
            of: home.path + "/",
            with: ""
        )
        let track = makeTrack()
        let record = OfflineTrackRecord(
            track: track,
            relativePath: relativePath,
            storage: .hlsPackage,
            retention: .manual,
            byteCount: 8,
            downloadedAt: Date(),
            lastPlayedAt: Date(),
            playCount: 0
        )
        let accountDirectory = root.appendingPathComponent(
            "42",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: accountDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([record]).write(
            to: accountDirectory.appendingPathComponent("index.json")
        )

        store.configure(accountID: 42)
        XCTAssertTrue(store.contains(track))
        XCTAssertEqual(store.downloadedTrackCount, 1)

        store.remove(track)
        XCTAssertFalse(store.contains(track))
        XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.path))
    }

    func testBatchOfHLSAndDirectTracksSharesOneCoordinator() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DownloadCoordinator()
        let store = OfflineTrackStore(
            rootURL: root,
            downloadService: try makeHLSDownloadService(),
            downloadCoordinator: coordinator
        )
        let hls = makeHLSTrack()
        let direct = makeTrack()
        store.configure(accountID: 42)

        async let first: Void = store.download(hls, userAgent: nil)
        async let second: Void = store.download(direct, userAgent: nil)
        _ = try await (first, second)

        XCTAssertEqual(store.downloadedTrackCount, 2)
        XCTAssertTrue(store.contains(hls))
        XCTAssertTrue(store.contains(direct))
    }

    func testFailedTrackProducesPartialBatch() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineURLProtocol.self]
        OfflineURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: request.url?.path.contains("bad") == true
                    ? 403
                    : 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "audio/mpeg",
                    "Content-Length": "8",
                ]
            )!
            return (response, Data("ID3audio".utf8))
        }
        let store = OfflineTrackStore(
            rootURL: root,
            downloadService: TrackShareService(
                session: URLSession(configuration: configuration)
            ),
            downloadCoordinator: DownloadCoordinator()
        )
        store.configure(accountID: 42)
        let goodTrack = makeTrack()
        let badTrack = Track(
            trackID: 8,
            ownerID: -42,
            title: "Bad",
            artist: "Artist",
            duration: 120,
            streamURL: URL(string: "https://example.com/bad.mp3"),
            artworkURL: nil
        )

        async let good: Void = store.download(goodTrack, userAgent: nil)
        async let bad: Void = store.download(badTrack, userAgent: nil)
        do {
            _ = try await bad
            XCTFail("The failing track must throw")
        } catch {
            // Expected.
        }
        _ = try? await good

        XCTAssertTrue(store.contains(goodTrack))
        XCTAssertFalse(store.contains(badTrack))
        XCTAssertEqual(store.downloadedTrackCount, 1)
    }

    func testRetryRecoversTransientHLSFailure() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try FragmentedMP4Fixture.make()
        let lock = NSLock()
        var failuresRemaining = 1
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineURLProtocol.self]
        OfflineURLProtocol.handler = { request in
            if request.url?.lastPathComponent == "index.m3u8" {
                lock.lock()
                let shouldFail = failuresRemaining > 0
                if shouldFail { failuresRemaining -= 1 }
                lock.unlock()
                if shouldFail {
                    let response = HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 503,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                    return (response, Data())
                }
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data(Self.hlsPlaylist.utf8))
            }
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            switch request.url?.lastPathComponent {
            case "init.mp4":
                return (response, fixture.initialization)
            case "frag1.m4s":
                return (response, fixture.fragments[0])
            default:
                return (
                    response,
                    fixture.fragments.count > 1
                        ? fixture.fragments[1]
                        : fixture.fragments[0]
                )
            }
        }
        let store = OfflineTrackStore(
            rootURL: root,
            downloadService: TrackShareService(
                session: URLSession(configuration: configuration)
            ),
            downloadCoordinator: DownloadCoordinator()
        )
        store.configure(accountID: 42)

        try await store.download(makeHLSTrack(), userAgent: nil)

        XCTAssertTrue(store.contains(makeHLSTrack()))
        XCTAssertEqual(store.downloadedTrackCount, 1)
    }

    // MARK: - Helpers

    private static let hlsPlaylist = """
    #EXTM3U
    #EXT-X-VERSION:7
    #EXT-X-MEDIA-SEQUENCE:0
    #EXT-X-MAP:URI="init.mp4"
    #EXTINF:0.1,
    frag1.m4s
    #EXTINF:0.1,
    frag2.m4s
    #EXT-X-ENDLIST
    """

    private func makeHLSDownloadService() throws -> TrackShareService {
        let fixture = try FragmentedMP4Fixture.make()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineURLProtocol.self]
        OfflineURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if url.pathExtension.lowercased() == "mp3" {
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "audio/mpeg",
                        "Content-Length": "8",
                    ]
                )!
                return (response, Data("ID3audio".utf8))
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            switch url.lastPathComponent {
            case "index.m3u8":
                return (response, Data(Self.hlsPlaylist.utf8))
            case "init.mp4":
                return (response, fixture.initialization)
            case "frag1.m4s":
                return (response, fixture.fragments[0])
            default:
                return (
                    response,
                    fixture.fragments.count > 1
                        ? fixture.fragments[1]
                        : fixture.fragments[0]
                )
            }
        }
        return TrackShareService(
            session: URLSession(configuration: configuration)
        )
    }

    private func makeHLSTrack() -> Track {
        Track(
            trackID: 77,
            ownerID: -42,
            title: "HLS Title",
            artist: "Artist",
            duration: 120,
            streamURL: URL(string: "https://example.com/hls/index.m3u8"),
            artworkURL: nil
        )
    }

    private func makeDownloadService() -> TrackShareService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineURLProtocol.self]
        OfflineURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "audio/mpeg",
                    "Content-Length": "8"
                ]
            )!
            return (response, Data("ID3audio".utf8))
        }
        return TrackShareService(
            session: URLSession(configuration: configuration)
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OfflineTrackStoreTests-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    private func makeTrack() -> Track {
        Track(
            trackID: 7,
            ownerID: -42,
            title: "Title",
            artist: "Artist",
            duration: 120,
            streamURL: URL(string: "https://example.com/track.mp3"),
            artworkURL: nil
        )
    }
}

private final class OfflineURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.unknown)
            )
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
