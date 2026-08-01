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

    @MainActor
    func testDirectExportReportsDownloadingProgress() async throws {
        let sourceURL = URL(string: "https://example.com/audio/track.mp3")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShareURLProtocol.self]
        ShareURLProtocol.handler = { _ in
            let response = HTTPURLResponse(
                url: sourceURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "audio/mpeg"]
            )!
            return (response, Data("ID3audio".utf8))
        }

        let service = TrackShareService(
            session: URLSession(configuration: configuration)
        )
        var values: [TrackExportProgress] = []

        let payload = try await service.preparePayload(
            for: makeTrack(streamURL: sourceURL),
            userAgent: nil,
            progress: { values.append($0) }
        )

        XCTAssertTrue(values.contains(.downloadingDirectFile))
        await service.removeExportedFile(payload)
    }

    @MainActor
    func testLocalFileReportsCopyingAndDoesNotModifySource() async throws {
        let service = TrackShareService()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")
        let bytes = Data("ID3audio".utf8)
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        var values: [TrackExportProgress] = []
        let payload = try await service.payloadFromLocalFile(
            source,
            track: makeTrack(streamURL: nil),
            requiresMP3: false,
            progress: { values.append($0) }
        )

        XCTAssertTrue(values.contains(.copyingLocalFile))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try Data(contentsOf: payload.fileURL), bytes)

        await service.removeExportedFile(payload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.fileURL.path))
    }

    @MainActor
    func testDirectM4AKeepsItsExtension() async throws {
        let service = TrackShareService()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        let m4aBytes = Data(
            [0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70] + Array("M4A ".utf8)
        )
        try m4aBytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let payload = try await service.payloadFromLocalFile(
            source,
            track: makeTrack(streamURL: nil),
            requiresMP3: false
        )

        XCTAssertEqual(payload.fileURL.pathExtension, "m4a")
        XCTAssertEqual(try Data(contentsOf: payload.fileURL), m4aBytes)
        await service.removeExportedFile(payload)
    }

    @MainActor
    func testSafeFilenameStripsPathAndControlCharacters() async throws {
        let service = TrackShareService()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")
        try Data("ID3audio".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let nastyArtist = "Artist/\\:*?\"<>|\n\tName"
        let nastyTitle = "Title"
        let track = Track(
            trackID: 7,
            ownerID: -42,
            title: nastyTitle,
            artist: nastyArtist,
            duration: 120,
            streamURL: nil,
            artworkURL: nil
        )

        let payload = try await service.payloadFromLocalFile(
            source,
            track: track,
            requiresMP3: false
        )
        defer {
            Task { await service.removeExportedFile(payload) }
        }

        let fileName = payload.fileURL.lastPathComponent
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
            .union(.controlCharacters)
            .union(.newlines)
        XCTAssertNil(fileName.rangeOfCharacter(from: invalid))
        XCTAssertFalse(fileName.contains(".."))
        XCTAssertEqual(payload.fileURL.deletingLastPathComponent().pathExtension, "")
    }

    @MainActor
    func testCleanupCannotRemoveURLOutsideExportRoot() async throws {
        let service = TrackShareService()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")
        try Data("ID3audio".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        await service.removeExportedFile(.audioFile(outside))

        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    @MainActor
    func testStaleExportsOnlyRemoveOldDirectories() async throws {
        let service = TrackShareService()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateMusicShare", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let old = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fresh = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appendingPathComponent("a.mp3"))
        try Data("fresh".utf8).write(to: fresh.appendingPathComponent("b.mp3"))
        let past = Date().addingTimeInterval(-86_400 * 2)
        try FileManager.default.setAttributes(
            [.modificationDate: past],
            ofItemAtPath: old.path
        )
        let looseFile = root.appendingPathComponent("loose.mp3")
        try Data("loose".utf8).write(to: looseFile)

        await service.removeStaleExports(olderThan: Date().addingTimeInterval(-86_400))

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: looseFile.path))
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
