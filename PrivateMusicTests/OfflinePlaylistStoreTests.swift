import XCTest
@testable import PrivateMusic

@MainActor
final class OfflinePlaylistStoreTests: XCTestCase {
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

    func testCancellationStopsActiveWork() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let playlist = try makePlaylist(id: 11, ownerID: 2)
        let tracks = (0..<20).map(makeTrack)
        let started = expectation(description: "download started")
        started.assertForOverFulfill = false
        let store = OfflinePlaylistStore(rootURL: root)
        store.configure(accountID: 1)

        store.startDownload(
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
        store.cancelDownload(for: playlist)
        await store.waitForDownload(of: playlist)

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

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "OfflinePlaylistStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func makePlaylist(
        id: Int,
        ownerID: Int,
        artwork: String? = nil
    ) throws -> Playlist {
        var object: [String: Any] = [
            "id": id,
            "owner_id": ownerID,
            "title": "Playlist \(id)",
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
