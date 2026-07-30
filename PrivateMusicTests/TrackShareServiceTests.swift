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
                    "Content-Length": "5"
                ]
            )!
            return (response, Data("audio".utf8))
        }
        let service = TrackShareService(
            session: URLSession(configuration: configuration)
        )

        let payload = try await service.preparePayload(
            for: makeTrack(streamURL: sourceURL),
            userAgent: "PrivateMusicTests"
        )

        guard case let .audioFile(fileURL) = payload else {
            return XCTFail("Direct audio must be exported as an attachment")
        }
        XCTAssertEqual(fileURL.pathExtension, "mp3")
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("audio".utf8))
        await service.removeExportedFile(payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testHLSUsesStableVKLinkWithoutSignedStreamParameters() async throws {
        let track = makeTrack(
            streamURL: URL(
                string: "https://example.com/audio/index.m3u8?token=secret"
            )
        )
        let service = TrackShareService()

        let payload = try await service.preparePayload(
            for: track,
            userAgent: "PrivateMusicTests"
        )

        XCTAssertEqual(
            payload,
            .vkLink(
                url: URL(string: "https://vk.com/audio-42_7")!,
                description: "Artist — Title"
            )
        )
        if case let .vkLink(url, _) = payload {
            XCTAssertNil(url.query)
            XCTAssertFalse(url.absoluteString.contains("secret"))
        } else {
            XCTFail("HLS must be shared as a stable VK link")
        }
    }

    func testMissingStreamStillProducesUsefulSharePayload() async {
        let service = TrackShareService()

        let payload = await service.linkPayload(
            for: makeTrack(streamURL: nil)
        )

        XCTAssertEqual(
            payload,
            .vkLink(
                url: URL(string: "https://vk.com/audio-42_7")!,
                description: "Artist — Title"
            )
        )
    }

    func testOnlyTemporaryExportCanBeCleanedUp() async throws {
        let service = TrackShareService()
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")
        try Data("audio".utf8).write(to: temporaryURL)

        await service.removeExportedFile(.audioFile(temporaryURL))

        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
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
