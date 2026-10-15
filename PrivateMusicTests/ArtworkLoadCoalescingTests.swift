import UIKit
import XCTest
@testable import PrivateMusic

@MainActor
final class ArtworkLoadCoalescingTests: XCTestCase {
    func testVisibleRowsAndPrefetchShareOneTransferAndBitmap() async throws {
        let (cache, session, url) = makeCache()
        defer { session.invalidateAndCancel() }
        async let prefetch: Void = cache.prefetch(url: url, maxPixelSize: 128)
        let successes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<24 {
                group.addTask { await cache.loadImage(url: url, maxPixelSize: 128) != nil }
            }
            var count = 0
            for await succeeded in group where succeeded { count += 1 }
            return count
        }
        await prefetch
        XCTAssertEqual(successes, 24)
        XCTAssertEqual(ProfilingArtworkProtocol.requestCount, 1)
        let image = try XCTUnwrap(cache.image(for: url, maxPixelSize: 128))
        XCTAssertLessThanOrEqual(image.cgImage?.width ?? .max, 128)
        let reused = await cache.loadImage(url: url, maxPixelSize: 128)
        XCTAssertTrue(reused === image)
        XCTAssertEqual(ProfilingArtworkProtocol.requestCount, 1)
    }

    func testCancellingOneVisibleRowKeepsAnotherRowsLoadAlive() async throws {
        let (cache, session, url) = makeCache()
        defer { session.invalidateAndCancel() }
        let first = Task { await cache.loadImage(url: url, maxPixelSize: 128) }
        let second = Task { await cache.loadImage(url: url, maxPixelSize: 128) }
        try await Task.sleep(for: .milliseconds(40))
        first.cancel()
        let survivor = await second.value
        let cancelled = await first.value
        XCTAssertNotNil(survivor)
        XCTAssertNil(cancelled)
        XCTAssertEqual(ProfilingArtworkProtocol.requestCount, 1)
    }

    func testAnUnusedLoadCancelsTheNetworkRequest() async throws {
        let (cache, session, url) = makeCache()
        defer { session.invalidateAndCancel() }
        let load = Task { await cache.loadImage(url: url, maxPixelSize: 128) }
        for _ in 0..<100 where ProfilingArtworkProtocol.requestCount == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(ProfilingArtworkProtocol.requestCount, 1)
        load.cancel()
        let result = await load.value
        for _ in 0..<100 where ProfilingArtworkProtocol.stopCount == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(result)
        XCTAssertNil(cache.image(for: url, maxPixelSize: 128))
        XCTAssertGreaterThanOrEqual(ProfilingArtworkProtocol.stopCount, 1)
    }

    private func makeCache() -> (ArtworkImageCache, URLSession, URL) {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512))
        let data = renderer.pngData { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        }
        ProfilingArtworkProtocol.reset(data: data)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProfilingArtworkProtocol.self]
        let session = URLSession(configuration: configuration)
        return (ArtworkImageCache(session: session), session,
                URL(string: "https://artwork.invalid/\(UUID().uuidString).png")!)
    }
}

private final class ProfilingArtworkProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requests = 0
    private static var stops = 0
    private static var data = Data()
    private var delivery: DispatchWorkItem?

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
    static var stopCount: Int {
        lock.lock(); defer { lock.unlock() }
        return stops
    }
    static func reset(data: Data) {
        lock.lock(); defer { lock.unlock() }
        requests = 0
        stops = 0
        self.data = data
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1
        let data = Self.data
        Self.lock.unlock()
        let delivery = DispatchWorkItem { [weak self] in
            guard let self, let url = self.request.url else { return }
            let response = HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "image/png"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        self.delivery = delivery
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2, execute: delivery)
    }
    override func stopLoading() {
        delivery?.cancel()
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.stops += 1
    }
}
