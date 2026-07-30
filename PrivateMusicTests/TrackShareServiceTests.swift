import XCTest
@testable import PrivateMusic

final class TrackShareServiceTests: XCTestCase {
    func testDirectAudioBecomesTemporaryShareAttachment() async throws {
        let sourceURL = URL(string: "https://example.com/audio/track.mp3")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShareURLProtocol.self]
        ShareURLProtocol.handler = { request in
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Referer"),
                "https://vk.com/"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "User-Agent"),
                "PrivateMusicTests"
            )
            let response = HTTPURLResponse(
                url: sourceURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "audio/mpeg",
                    "Content-Length": "8"
                ]
            )!
            return (response, Data("ID3audio".utf8))
        }
        let service = TrackShareService(
            session: URLSession(configuration: configuration)
        )

        let payload = try await service.preparePayload(
            for: makeTrack(streamURL: sourceURL),
            userAgent: "PrivateMusicTests",
            requiresMP3: true
        )

        guard case let .audioFile(fileURL) = payload else {
            return XCTFail("Direct audio must be exported as an attachment")
        }
        XCTAssertEqual(fileURL.pathExtension, "mp3")
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("ID3audio".utf8))
        await service.removeExportedFile(payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testHLSNeverFallsBackToAStreamingLink() async {
        let track = makeTrack(
            streamURL: URL(
                string: "https://example.com/audio/index.m3u8?token=secret"
            )
        )
        let service = TrackShareService()

        do {
            _ = try await service.preparePayload(
                for: track,
                userAgent: "PrivateMusicTests",
                requiresMP3: true
            )
            XCTFail("HLS must not be shared as an MP3 or a link")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("token=secret"))
        }
    }

    func testDisguisedHLSBodyIsRejected() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShareURLProtocol.self]
        ShareURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "audio/mpeg"]
            )!
            return (
                response,
                Data("#EXTM3U\n#EXT-X-VERSION:3".utf8)
            )
        }
        let service = TrackShareService(
            session: URLSession(configuration: configuration)
        )

        do {
            _ = try await service.preparePayload(
                for: makeTrack(
                    streamURL: URL(
                        string: "https://example.com/audio.mp3"
                    )
                ),
                userAgent: nil,
                requiresMP3: true
            )
            XCTFail("A playlist must never be exported as MP3")
        } catch {
            XCTAssertNotNil(error as? APIError)
        }
    }

    func testMissingStreamFailsInsteadOfSharingVKLink() async {
        let service = TrackShareService()
        do {
            _ = try await service.preparePayload(
                for: makeTrack(streamURL: nil),
                userAgent: nil,
                requiresMP3: true
            )
            XCTFail("A missing stream must fail")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testOnlyTemporaryExportCanBeCleanedUp() async throws {
        let service = TrackShareService()
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")
        try Data("ID3audio".utf8).write(to: sourceURL)
        let payload = try await service.payloadFromLocalFile(
            sourceURL,
            track: makeTrack(streamURL: nil)
        )
        let temporaryURL = payload.fileURL

        await service.removeExportedFile(payload)

        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        try? FileManager.default.removeItem(at: sourceURL)
    }

    private func makeTrack(streamURL: URL?) -> Track {
        Track(
            trackID: 7,
            ownerID: -42,
            title: "Title",
            artist: "Artist",
            duration: 120,
            streamURL: streamURL,
            artworkURL: nil
        )
    }
}

private final class ShareURLProtocol: URLProtocol {
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
