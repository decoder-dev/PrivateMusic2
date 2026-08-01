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
