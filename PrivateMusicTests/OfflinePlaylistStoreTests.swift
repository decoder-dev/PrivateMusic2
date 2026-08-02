import XCTest
@testable import PrivateMusic

@MainActor
final class OfflinePlaylistStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        OfflineDownloadsFeature.testingOverride = true
    }

    override func tearDown() {
        OfflineDownloadsFeature.testingOverride = nil
        super.tearDown()
    }

    func testDownloadsAllPagesPreservesOrderAndPersists() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let playlist = try makePlaylist(id: 9, ownerID: -4)
        let tracks = (0..<205).map(makeTrack)
        let store = OfflinePlaylistStore(rootURL: root)
        store.configure(accountID: 42)

        store.startDownload(
            playlist: playlist,
            fetchPage: { offset in
                let end = min(offset + 100, tracks.count)
                let items = offset < end
                    ? Array(tracks[offset..<end])
                    : []
                return MusicPage(
                    items: items,
                    totalCount: tracks.count,
                    nextOffset: end < tracks.count ? end : nil
                )
            },
            downloadTrack: { _ in }
        )
        await store.waitForDownload(of: playlist)

        let record = try XCTUnwrap(store.record(for: playlist))
        XCTAssertEqual(record.state, .available)
        XCTAssertEqual(record.completedCount, 205)
        XCTAssertEqual(record.tracks.map(\.id), tracks.map(\.id))
        XCTAssertTrue(record.tracks.allSatisfy { $0.streamURL == nil })

        let restored = OfflinePlaylistStore(rootURL: root)
        restored.configure(accountID: 42)
        XCTAssertEqual(restored.record(for: playlist), record)
    }

    func testProgressCountsFailuresAndProducesPartialRecord() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let playlist = try makePlaylist(id: 10, ownerID: 2)
        let tracks = (0..<4).map(makeTrack)
        let store = OfflinePlaylistStore(rootURL: root)
        store.configure(accountID: 1)

        store.startDownload(
            playlist: playlist,
            fetchPage: { _ in
                MusicPage(items: tracks, totalCount: 4, nextOffset: nil)
            },
            downloadTrack: { track in
                if track.trackID == 2 {
                    throw URLError(.cannotConnectToHost)
                }
            }
        )
        await store.waitForDownload(of: playlist)

        let record = try XCTUnwrap(store.record(for: playlist))
        XCTAssertEqual(record.state, .partial)
        XCTAssertEqual(record.completedCount, 3)
        XCTAssertEqual(record.failedCount, 1)
        XCTAssertEqual(record.progress, 1)
    }

    func testPlaylistDownloadUsesAtMostThreeWorkers() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let playlist = try makePlaylist(id: 27, ownerID: 2)
        let tracks = (0..<30).map(makeTrack)
        let concurrency = PlaylistConcurrencyTracker()
        let store = OfflinePlaylistStore(rootURL: root)
        store.configure(accountID: 1)

        store.startDownload(
            playlist: playlist,
            fetchPage: { _ in
                MusicPage(
                    items: tracks,
                    totalCount: tracks.count,
                    nextOffset: nil
                )
            },
            downloadTrack: { _ in
                concurrency.enter()
                defer { concurrency.exit() }
                try await Task.sleep(for: .milliseconds(25))
            }
        )
        await store.waitForDownload(of: playlist)

        XCTAssertEqual(store.record(for: playlist)?.state, .available)
        XCTAssertEqual(store.record(for: playlist)?.completedCount, tracks.count)
        XCTAssertLessThanOrEqual(
            concurrency.maximum,
            DownloadCoordinator.maximumConcurrentDownloads
        )
        XCTAssertGreaterThan(concurrency.maximum, 1)
    }

    func testCancellationStopsActiveWork() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let playlist = try makePlaylist(id: 11, ownerID: 2)
        let tracks = (0..<20).map(makeTrack)
        let started = expectation(description: "download started")
        started.assertForOverFulfill = false
        let store = OfflinePlaylistStore(rootURL: root)
        store.configure(accountID: 1)

        let task = store.startDownload(
            playlist: playlist,
            fetchPage: { _ in
                MusicPage(items: tracks, totalCount: 20, nextOffset: nil)
            },
            downloadTrack: { _ in
                started.fulfill()
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
        )
        await fulfillment(of: [started], timeout: 1)
        let cancelledTask = store.cancelDownload(for: playlist)
        await cancelledTask?.value
        await task.value

        XCTAssertEqual(store.record(for: playlist)?.state, .cancelled)
        XCTAssertLessThan(
            store.record(for: playlist)?.completedCount ?? 20,
            tracks.count
        )
    }

    func testArtworkIsStoredLocallyAndRemovedWithPlaylist() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaylistArtworkURLProtocol.self]
        PlaylistArtworkURLProtocol.responseData = onePixelPNG
        let store = OfflinePlaylistStore(
            rootURL: root,
            artworkSession: URLSession(configuration: configuration)
        )
        let playlist = try makePlaylist(
            id: 12,
            ownerID: 2,
            artwork: "https://example.com/cover.png"
        )
        store.configure(accountID: 7)

        store.startDownload(
            playlist: playlist,
            fetchPage: { _ in
                MusicPage(items: [], totalCount: 0, nextOffset: nil)
            },
            downloadTrack: { _ in }
        )
        await store.waitForDownload(of: playlist)

        let artworkURL = try XCTUnwrap(
            store.localArtworkURL(for: playlist)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: artworkURL.path))

        store.remove(playlist)
        XCTAssertNil(store.record(for: playlist))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: artworkURL.path)
        )
    }

    func testAccountsAreIsolated() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let playlist = try makePlaylist(id: 13, ownerID: 2)
        let store = OfflinePlaylistStore(rootURL: root)
        store.configure(accountID: 7)
        store.startDownload(
            playlist: playlist,
            fetchPage: { _ in
                MusicPage(items: [], totalCount: 0, nextOffset: nil)
            },
            downloadTrack: { _ in }
        )

        store.configure(accountID: 8)
        XCTAssertNil(store.record(for: playlist))
    }

    func testPreparingStatusWhileTracksResolve() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let playlist = try makePlaylist(id: 20, ownerID: 2)
        let fetchStarted = expectation(description: "fetch page started")
        fetchStarted.assertForOverFulfill = false
        let release = AsyncStream<Void>.makeStream()
        let track = makeTrack(0)
        let store = OfflinePlaylistStore(rootURL: root)
        store.configure(accountID: 1)

        store.startDownload(
            playlist: playlist,
            fetchPage: { _ in
                fetchStarted.fulfill()
                _ = await release.stream.first(where: { _ in true })
                return MusicPage(items: [track], totalCount: 1, nextOffset: nil)
            },
            downloadTrack: { _ in }
        )
        await fulfillment(of: [fetchStarted], timeout: 1)
        XCTAssertEqual(
            store.record(for: playlist)?.state,
            .resolvingTracks
        )

        release.continuation.yield()
        release.continuation.finish()
        await store.waitForDownload(of: playlist)

        let record = try XCTUnwrap(store.record(for: playlist))
        XCTAssertEqual(record.state, .available)
    }

    func testRestartAfterCancelResetsCountersAndCompletes() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let playlist = try makePlaylist(id: 21, ownerID: 2)
        let tracks = (0..<4).map(makeTrack)
        let store = OfflinePlaylistStore(rootURL: root)
        store.configure(accountID: 1)

        let first = store.startDownload(
            playlist: playlist,
            fetchPage: { _ in
                try await Task.sleep(for: .milliseconds(200))
                return MusicPage(items: tracks, totalCount: 4, nextOffset: nil)
            },
            downloadTrack: { _ in }
        )
        store.cancelDownload(for: playlist)
        XCTAssertEqual(store.record(for: playlist)?.state, .cancelled)

        let second = store.startDownload(
            playlist: playlist,
            fetchPage: { _ in
                MusicPage(items: tracks, totalCount: 4, nextOffset: nil)
            },
            downloadTrack: { _ in }
        )
        await second.value
        XCTAssertEqual(store.record(for: playlist)?.state, .available)
        XCTAssertEqual(store.record(for: playlist)?.completedCount, 4)

        await first.value
        XCTAssertEqual(store.record(for: playlist)?.state, .available)
        XCTAssertEqual(store.record(for: playlist)?.completedCount, 4)
    }

    func testStartDownloadRefreshesPlaylistMetadata() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let playlist = try makePlaylist(id: 22, ownerID: 2)
        let tracks = (0..<4).map(makeTrack)
        let store = OfflinePlaylistStore(rootURL: root)
        store.configure(accountID: 1)

        store.startDownload(
            playlist: playlist,
            fetchPage: { _ in
                MusicPage(items: tracks, totalCount: 4, nextOffset: nil)
            },
            downloadTrack: { _ in }
        )
        await store.waitForDownload(of: playlist)
        XCTAssertEqual(
            store.record(for: playlist)?.playlist.title,
            "Playlist 22"
        )

        let renamed = try makePlaylist(id: 22, ownerID: 2, title: "Renamed")
        store.startDownload(
            playlist: renamed,
            fetchPage: { _ in
                MusicPage(items: tracks, totalCount: 4, nextOffset: nil)
            },
            downloadTrack: { _ in }
        )
        await store.waitForDownload(of: playlist)
        XCTAssertEqual(store.record(for: playlist)?.playlist.title, "Renamed")
    }

    func testDuplicateStartReturnsSameTask() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let playlist = try makePlaylist(id: 23, ownerID: 2)
        let store = OfflinePlaylistStore(rootURL: root)
        store.configure(accountID: 1)

        var fetchCount = PageCounter()
        let first = store.startDownload(
            playlist: playlist,
            fetchPage: { _ in
                fetchCount.increment()
                try await Task.sleep(for: .milliseconds(100))
                return MusicPage(items: [], totalCount: 0, nextOffset: nil)
            },
            downloadTrack: { _ in }
        )
        let second = store.startDownload(
            playlist: playlist,
            fetchPage: { _ in
                fetchCount.increment()
                return MusicPage(items: [], totalCount: 0, nextOffset: nil)
            },
            downloadTrack: { _ in }
        )
        await first.value
        await second.value
        XCTAssertEqual(fetchCount.value, 1)
    }

    func testPartialPagesAreFetchedUntilAllTracksKnown() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let playlist = try makePlaylist(id: 24, ownerID: 2)
        let tracks = (0..<1000).map(makeTrack)
        let pageCounter = PageCounter()
        let store = OfflinePlaylistStore(rootURL: root)
        store.configure(accountID: 1)

        store.startDownload(
            playlist: playlist,
            fetchPage: { offset in
                pageCounter.increment()
                let end = min(offset + 100, tracks.count)
                let items = offset < end
                    ? Array(tracks[offset..<end])
                    : []
                return MusicPage(
                    items: items,
                    totalCount: tracks.count,
                    nextOffset: end < tracks.count ? end : nil
                )
            },
            downloadTrack: { _ in }
        )
        await store.waitForDownload(of: playlist)

        let record = try XCTUnwrap(store.record(for: playlist))
        XCTAssertEqual(record.state, .available)
        XCTAssertEqual(record.completedCount, 1000)
        XCTAssertEqual(record.tracks.count, 1000)
        XCTAssertEqual(pageCounter.value, 10)
    }

    func testPendingSaveDoesNotLeakIntoOtherAccount() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let playlist = try makePlaylist(id: 25, ownerID: 2)
        let store = OfflinePlaylistStore(rootURL: root)
        store.configure(accountID: 1)

        store.startDownload(
            playlist: playlist,
            fetchPage: { _ in
                try await Task.sleep(for: .milliseconds(200))
                return MusicPage(items: [], totalCount: 0, nextOffset: nil)
            },
            downloadTrack: { _ in }
        )
        store.configure(accountID: 2)
        store.configure(accountID: 1)
        await store.waitForDownload(of: playlist)

        XCTAssertNil(store.record(for: playlist))
    }

    func testAccountSwitchRemovesResolvedJobWithNoCompletedTracks() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let playlist = try makePlaylist(id: 29, ownerID: 2)
        let track = makeTrack(1)
        let started = expectation(description: "track download started")
        started.assertForOverFulfill = false
        let store = OfflinePlaylistStore(rootURL: root)
        store.configure(accountID: 1)

        let task = store.startDownload(
            playlist: playlist,
            fetchPage: { _ in
                MusicPage(items: [track], totalCount: 1, nextOffset: nil)
            },
            downloadTrack: { _ in
                started.fulfill()
                try await Task.sleep(for: .seconds(5))
            }
        )
        await fulfillment(of: [started], timeout: 1)
        try await Task.sleep(for: .milliseconds(400))
        store.configure(accountID: 2)
        await task.value

        let restored = OfflinePlaylistStore(rootURL: root)
        restored.configure(accountID: 1)
        XCTAssertNil(restored.record(for: playlist))
    }

    func testConfigureFlushesPendingRemovalForPreviousAccount() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let playlist = try makePlaylist(id: 28, ownerID: 2)
        let store = OfflinePlaylistStore(rootURL: root)
        store.configure(accountID: 1)
        let track = makeTrack(1)
        store.startDownload(
            playlist: playlist,
            fetchPage: { _ in
                MusicPage(items: [track], totalCount: 1, nextOffset: nil)
            },
            downloadTrack: { _ in }
        )
        await store.waitForDownload(of: playlist)
        store.remove(playlist)
        store.configure(accountID: 2)

        let restored = OfflinePlaylistStore(rootURL: root)
        restored.configure(accountID: 1)
        XCTAssertNil(restored.record(for: playlist))
    }

    func testPlaylistStatusMapping() throws {
        let playlist = try makePlaylist(id: 26, ownerID: 2)

        let resolving = OfflinePlaylistRecord(
            playlist: playlist,
            state: .resolvingTracks
        )
        XCTAssertEqual(
            OfflinePlaylistStatus.status(for: resolving),
            .preparing
        )
        XCTAssertTrue(OfflinePlaylistStatus.status(for: resolving).isActive)
        XCTAssertEqual(resolving.progress, 0)

        let queued = OfflinePlaylistRecord(
            playlist: playlist,
            state: .queued
        )
        XCTAssertEqual(OfflinePlaylistStatus.status(for: queued), .queued)
        XCTAssertTrue(OfflinePlaylistStatus.status(for: queued).isActive)

        var downloading = OfflinePlaylistRecord(
            playlist: playlist,
            state: .downloading
        )
        downloading.processedCount = 5
        downloading.completedCount = 3
        downloading.failedCount = 2
        let active = OfflinePlaylistStatus.status(for: downloading)
        XCTAssertEqual(
            active,
            .downloading(processed: 5, total: 205, succeeded: 3, failed: 2)
        )
        XCTAssertEqual(
            try XCTUnwrap(active.progress),
            5.0 / 205.0,
            accuracy: 0.0001
        )
        XCTAssertTrue(active.isActive)
        XCTAssertNotNil(active.localizedText)

        var available = OfflinePlaylistRecord(
            playlist: playlist,
            state: .available
        )
        available.completedCount = 205
        available.processedCount = 205
        XCTAssertEqual(
            OfflinePlaylistStatus.status(for: available),
            .completed(count: 205, total: 205)
        )
        XCTAssertEqual(available.progress, 1)
        XCTAssertFalse(OfflinePlaylistStatus.status(for: available).isActive)

        var partial = OfflinePlaylistRecord(
            playlist: playlist,
            state: .partial
        )
        partial.completedCount = 3
        partial.failedCount = 1
        XCTAssertEqual(
            OfflinePlaylistStatus.status(for: partial),
            .partial(count: 3, total: 205)
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "OfflinePlaylistStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private final class PageCounter: @unchecked Sendable {
        private var _value = 0
        var value: Int {
            lock.withLock { _value }
        }
        func increment() {
            lock.withLock { _value += 1 }
        }
        private let lock = NSLock()
    }

    private func makePlaylist(
        id: Int,
        ownerID: Int,
        artwork: String? = nil,
        title: String = ""
    ) throws -> Playlist {
        var object: [String: Any] = [
            "id": id,
            "owner_id": ownerID,
            "title": title.isEmpty ? "Playlist \(id)" : title,
            "count": 205
        ]
        object["photo_600"] = artwork
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(Playlist.self, from: data)
    }

    private func makeTrack(_ id: Int) -> Track {
        Track(
            trackID: id,
            ownerID: 1,
            title: "Track \(id)",
            artist: "Artist",
            duration: 120,
            streamURL: URL(string: "https://example.com/\(id).mp3"),
            artworkURL: nil
        )
    }

    private var onePixelPNG: Data {
        Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC"
                + "AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
    }
}

private final class PlaylistConcurrencyTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var peak = 0

    var maximum: Int {
        lock.withLock { peak }
    }

    func enter() {
        lock.withLock {
            active += 1
            peak = max(peak, active)
        }
    }

    func exit() {
        lock.withLock { active -= 1 }
    }
}

private final class PlaylistArtworkURLProtocol: URLProtocol {
    static var responseData = Data()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "image/png",
                "Content-Length": String(Self.responseData.count)
            ]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
