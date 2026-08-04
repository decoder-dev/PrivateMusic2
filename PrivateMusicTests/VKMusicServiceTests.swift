import XCTest
@testable import PrivateMusic

final class VKMusicServiceTests: XCTestCase {
    private func makeService() -> VKMusicService {
        VKMusicService(
            client: APIClient(
                baseURL: URL(string: "https://example.com")!
            ),
            apiVersion: "5.131"
        )
    }

    // Defect 15: a page with fewer items than requested (e.g. 50 of 100 for
    // a 1000-track playlist) must still advance the offset, otherwise large
    // playlists silently truncate.
    func testPageContinuesWhenServerReturnsFewerItemsThanRequested() {
        let service = makeService()
        let items = (0..<50).map { $0 }

        let page = service.page(
            VKItems(count: 1000, items: items),
            offset: 0,
            requested: 100
        )

        XCTAssertEqual(page.nextOffset, 50)
        XCTAssertEqual(page.totalCount, 1000)
        XCTAssertEqual(page.items.count, 50)
    }

    func testPageAdvancesByExactItemCountOnFullPage() {
        let service = makeService()
        let page = service.page(
            VKItems(count: 1000, items: Array(0..<100)),
            offset: 0,
            requested: 100
        )

        XCTAssertEqual(page.nextOffset, 100)
        XCTAssertEqual(page.totalCount, 1000)
    }

    func testPageStopsAfterLastPartialPage() {
        let service = makeService()
        let page = service.page(
            VKItems(count: 1000, items: Array(0..<50)),
            offset: 950,
            requested: 100
        )

        XCTAssertNil(page.nextOffset)
    }

    func testPageHandlesEmptyResponse() {
        let service = makeService()
        let page = service.page(
            VKItems(count: 0, items: [Int]()),
            offset: 0,
            requested: 100
        )

        XCTAssertNil(page.nextOffset)
        XCTAssertEqual(page.totalCount, 0)
    }

    func testPageFallsBackToItemCountWhenTotalMissing() {
        let service = makeService()
        let page = service.page(
            VKItems(count: nil, items: Array(0..<3)),
            offset: 0,
            requested: 100
        )

        XCTAssertEqual(page.totalCount, 3)
        XCTAssertNil(page.nextOffset)
    }

    func testAlbumExecuteRequestUsesPlaylistPagingContract() {
        let album = Album(
            id: 24,
            ownerID: -5,
            title: "Album",
            count: 120,
            accessKey: " secret "
        )

        let parameters = AlbumTrackRequestPolicy.executeParameters(
            album: album,
            offset: 40,
            count: 20
        )

        XCTAssertEqual(parameters["owner_id"], "-5")
        XCTAssertEqual(parameters["id"], "24")
        XCTAssertEqual(parameters["audio_offset"], "40")
        XCTAssertEqual(parameters["audio_count"], "20")
        XCTAssertEqual(parameters["access_key"], "secret")
        XCTAssertNil(parameters["album_id"])
    }

    func testAlbumLegacyRequestKeepsAudioGetContract() {
        let album = Album(
            id: 24,
            ownerID: -5,
            title: "Album",
            count: 120,
            accessKey: " "
        )

        let parameters = AlbumTrackRequestPolicy.legacyParameters(
            album: album,
            offset: 40,
            count: 20
        )

        XCTAssertEqual(parameters["owner_id"], "-5")
        XCTAssertEqual(parameters["album_id"], "24")
        XCTAssertEqual(parameters["offset"], "40")
        XCTAssertEqual(parameters["count"], "20")
        XCTAssertNil(parameters["id"])
        XCTAssertNil(parameters["access_key"])
    }

    func testExecutePlaylistResponseExtractsValidAlbumTracksLossily() throws {
        let data = """
        {
          "response": {
            "audios": [
              {
                "id": 1,
                "owner_id": -5,
                "title": "One",
                "artist": "Artist",
                "duration": 120
              },
              {"type": "ad"},
              {
                "id": 2,
                "owner_id": -5,
                "title": "Two",
                "artist": "Artist",
                "duration": 140
              }
            ],
            "playlist": {"id": 24, "owner_id": -5, "title": "Album"}
          }
        }
        """.data(using: .utf8)!

        let value = try JSONDecoder().decode(
            JSONValue.self,
            from: data
        )

        XCTAssertEqual(value.tracks.map(\.trackID), [1, 2])
    }

    // MARK: - catalogSections()

    /// Mixes and new releases both live inside `catalog.getAudio` blocks, so
    /// a session with both present must be resolved from a single request
    /// rather than the two independent requests `mixes()` and the old
    /// `newReleases()` used to make.
    func testCatalogSectionsIssuesSingleRequestWhenBothSectionsPresent() async throws {
        CatalogURLProtocol.reset()
        CatalogURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            XCTAssertEqual(path, "/method/catalog.getAudio")
            let json = """
            {
              "response": {
                "blocks": [
                  {
                    "mix_id": "mix-1",
                    "title": "Mix One",
                    "subtitle": "Subtitle"
                  },
                  {
                    "id": 5,
                    "owner_id": -10,
                    "title": "Album Title",
                    "year": 2024
                  }
                ]
              }
            }
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, json.data(using: .utf8)!)
        }

        let service = makeService(protocolClass: CatalogURLProtocol.self)
        let sections = try await service.catalogSections(
            accessToken: "token"
        )

        XCTAssertEqual(CatalogURLProtocol.requestCount, 1)
        XCTAssertEqual(sections.mixes.map(\.id), ["common", "mix-1"])
        XCTAssertEqual(sections.newReleases.map(\.title), ["Album Title"])
    }

    /// When the shared response has neither section, each missing section
    /// falls back to its own `catalog.getSection` call — but a section that
    /// is already present must not trigger a redundant fallback request.
    func testCatalogSectionsFallsBackOnlyForMissingSections() async throws {
        CatalogURLProtocol.reset()
        CatalogURLProtocol.handler = { request in
            let json: String
            if request.url?.path == "/method/catalog.getSection" {
                json = """
                { "response": { "blocks": [
                    {"mix_id": "mix-2", "title": "Mix Two", "subtitle": "S"}
                ] } }
                """
            } else {
                // catalog.getAudio: releases present, mixes absent.
                json = """
                { "response": { "blocks": [
                    {"id": 9, "owner_id": -1, "title": "Album", "year": 2023}
                ] } }
                """
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, json.data(using: .utf8)!)
        }

        let service = makeService(protocolClass: CatalogURLProtocol.self)
        let sections = try await service.catalogSections(
            accessToken: "token"
        )

        // One call to catalog.getAudio, one fallback call to
        // catalog.getSection for the missing mixes only.
        XCTAssertEqual(CatalogURLProtocol.requestCount, 2)
        XCTAssertEqual(sections.mixes.map(\.id), ["common", "mix-2"])
        XCTAssertEqual(sections.newReleases.map(\.title), ["Album"])
    }

    private func makeService(
        protocolClass: URLProtocol.Type
    ) -> VKMusicService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        let session = URLSession(configuration: configuration)
        return VKMusicService(
            client: APIClient(
                baseURL: URL(string: "https://example.com")!,
                session: session
            ),
            apiVersion: "5.131"
        )
    }
}

private final class CatalogURLProtocol: URLProtocol {
    static var handler: (
        (URLRequest) throws -> (HTTPURLResponse, Data)
    )?
    private static let lock = NSLock()
    private static var _requestCount = 0

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _requestCount
    }

    static func reset() {
        lock.lock()
        _requestCount = 0
        lock.unlock()
        handler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self._requestCount += 1
        Self.lock.unlock()
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
