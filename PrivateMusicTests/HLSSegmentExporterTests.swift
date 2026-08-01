import XCTest
@testable import PrivateMusic

@MainActor
final class HLSSegmentExporterTests: XCTestCase {
    private let mediaPlaylist = """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-MEDIA-SEQUENCE:0
    #EXTINF:5,
    seg1.ts
    #EXTINF:5,
    seg2.ts
    #EXTINF:5,
    seg3.ts
    #EXT-X-ENDLIST
    """

    func testSegmentProgressStartsAtZeroAndEndsAtTotal() async throws {
        let exporter = makeExporter { request in
            if request.url?.pathExtension == "m3u8" {
                return (Self.successResponse(for: request), Data(self.mediaPlaylist.utf8))
            }
            return (
                Self.successResponse(for: request),
                Data(repeating: 0x47, count: 512)
            )
        }
        let (parent, destination) = makeDestination()

        var values: [TrackExportProgress] = []
        try? await exporter.exportToM4A(
            streamURL: URL(string: "https://example.com/hls/index.m3u8")!,
            headers: ["Referer": "https://vk.com/"],
            destination: destination,
            fileSizeLimit: 150_000_000,
            progress: { values.append($0) }
        )

        let increments = values.compactMap { progress -> (Int, Int)? in
            guard case let .downloadingSegments(completed, total) = progress
            else { return nil }
            return (completed, total)
        }
        XCTAssertEqual(increments.map(\.0), [0, 1, 2, 3])
        XCTAssertEqual(increments.map(\.1), [3, 3, 3, 3])
        XCTAssertTrue(values.contains(.convertingToM4A))
        XCTAssertEqual(values.last, .convertingToM4A)
        XCTAssertNil(increments.firstIndex { $0.0 < 0 || $0.0 > $0.1 })
        try? FileManager.default.removeItem(at: parent)
    }

    func testByterangeRequestsCarryCorrectRangeHeaders() async throws {
        let byteRangePlaylist = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-BYTERANGE:100@0
        seg1.ts
        #EXT-X-BYTERANGE:100
        seg2.ts
        #EXT-X-ENDLIST
        """
        let lock = NSLock()
        var capturedRanges: [String] = []
        let exporter = makeExporter { request in
            if request.url?.pathExtension == "m3u8" {
                return (
                    Self.successResponse(for: request),
                    Data(byteRangePlaylist.utf8)
                )
            }
            if let range = request.value(forHTTPHeaderField: "Range") {
                lock.lock()
                capturedRanges.append(range)
                lock.unlock()
            }
            return (
                Self.successResponse(for: request),
                Data(repeating: 0x47, count: 100)
            )
        }
        let (parent, destination) = makeDestination()

        try? await exporter.exportToM4A(
            streamURL: URL(string: "https://example.com/hls/index.m3u8")!,
            headers: [:],
            destination: destination,
            fileSizeLimit: 150_000_000
        )

        lock.lock()
        let ranges = capturedRanges.sorted()
        lock.unlock()
        XCTAssertEqual(ranges, ["bytes=0-99", "bytes=100-199"])
        try? FileManager.default.removeItem(at: parent)
    }

    func testCancellationDeletesStagingAndDestination() async throws {
        let exporter = makeExporter { request in
            if request.url?.pathExtension == "m3u8" {
                return (Self.successResponse(for: request), Data(self.mediaPlaylist.utf8))
            }
            Thread.sleep(forTimeInterval: 0.3)
            return (
                Self.successResponse(for: request),
                Data(repeating: 0x47, count: 512)
            )
        }
        let (parent, destination) = makeDestination()

        var values: [TrackExportProgress] = []
        let task = Task {
            try await exporter.exportToM4A(
                streamURL: URL(string: "https://example.com/hls/index.m3u8")!,
                headers: [:],
                destination: destination,
                fileSizeLimit: 150_000_000,
                progress: { values.append($0) }
            )
        }
        while values.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(values.first, .downloadingSegments(completed: 0, total: 3))
        task.cancel()
        _ = try? await task.value

        let contents = try FileManager.default.contentsOfDirectory(
            atPath: parent.path
        )
        XCTAssertTrue(contents.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testKeyFailureDeletesStaging() async throws {
        let encryptedPlaylist = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x000102030405060708090a0b0c0d0e0f
        #EXTINF:5,
        seg1.ts
        #EXT-X-ENDLIST
        """
        let exporter = makeExporter { request in
            if request.url?.pathExtension == "m3u8" {
                return (
                    Self.successResponse(for: request),
                    Data(encryptedPlaylist.utf8)
                )
            }
            if request.url?.lastPathComponent == "key.bin" {
                return (Self.errorResponse(for: request), Data())
            }
            return (
                Self.successResponse(for: request),
                Data(repeating: 0x47, count: 512)
            )
        }
        let (parent, destination) = makeDestination()

        do {
            try await exporter.exportToM4A(
                streamURL: URL(string: "https://example.com/hls/index.m3u8")!,
                headers: [:],
                destination: destination,
                fileSizeLimit: 150_000_000
            )
            XCTFail("A failed key fetch must fail the export")
        } catch {
            XCTAssertNotNil(error as? HLSExportError)
        }

        let contents = try FileManager.default.contentsOfDirectory(
            atPath: parent.path
        )
        XCTAssertTrue(contents.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Helpers

    private func makeExporter(
        _ handler: @escaping (URLRequest) -> (HTTPURLResponse, Data)
    ) -> HLSSegmentExporter {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HLSURLProtocol.self]
        HLSURLProtocol.handler = handler
        return HLSSegmentExporter(
            session: URLSession(configuration: configuration)
        )
    }

    private func makeDestination() -> (URL, URL) {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "HLSSegmentExporterTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        return (parent, parent.appendingPathComponent("out.m4a"))
    }

    private static func successResponse(
        for request: URLRequest
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com/")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private static func errorResponse(
        for request: URLRequest
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com/")!,
            statusCode: 403,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}

private final class HLSURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

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
        let (response, data) = handler(request)
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
