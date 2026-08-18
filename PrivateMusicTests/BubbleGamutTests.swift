import XCTest
@testable import PrivateMusic

final class BubbleGamutTests: XCTestCase {
    /// Context legend colours must sit in the same luminance band so white
    /// labels on the Home rail read equally.
    func testContextLegendLuminanceIsMatched() {
        let roles: [BubbleRole] = [.station, .artist, .mood, .mix]
        let luminances = roles.map {
            BubbleGamut.components(for: $0).luminance
        }

        for value in luminances {
            XCTAssertGreaterThanOrEqual(value, 0.38)
            XCTAssertLessThanOrEqual(
                value,
                BubblePalette.surfaceLuminanceCeiling
            )
        }

        let spread = (luminances.max() ?? 0) - (luminances.min() ?? 0)
        XCTAssertLessThan(spread, 0.22)
    }

    func testAccentDiffersBetweenThemes() {
        XCTAssertNotEqual(
            BubbleGamut.accent(for: .dark),
            BubbleGamut.accent(for: .light)
        )
    }

    func testBubblePaletteFallbacksTrackTheGamut() {
        for role in BubbleRole.allCases {
            XCTAssertEqual(
                BubblePalette.fallback(role),
                BubbleGamut.components(for: role)
            )
        }
    }

    func testStatusColoursStayDistinctFromContextLegend() {
        let context = Set([
            BubbleGamut.station,
            BubbleGamut.artist,
            BubbleGamut.mood,
            BubbleGamut.mix
        ].map(\.self))
        let status = [
            BubbleGamut.success,
            BubbleGamut.warning,
            BubbleGamut.destructive
        ]

        for colour in status {
            XCTAssertFalse(context.contains(colour))
        }
    }
}

@MainActor
final class BubbleTintCacheTests: XCTestCase {
    func testRecordArtworkPopulatesCachedTint() {
        let cache = BubbleTintCache.shared
        let url = URL(string: "https://example.com/tint-test-\(UUID().uuidString).jpg")!
        let startRevision = cache.revision

        var pixels: [UInt8] = []
        for _ in 0..<64 {
            pixels.append(contentsOf: [220, 40, 30, 255])
        }
        let image = makeTestImage(rgba: pixels)
        cache.recordArtwork(image, for: url)

        XCTAssertGreaterThan(cache.revision, startRevision)
        XCTAssertNotNil(cache.cached(for: url))
    }

    private func makeTestImage(rgba: [UInt8]) -> UIImage {
        let edge = 8
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        var buffer = rgba
        let context = CGContext(
            data: &buffer,
            width: edge,
            height: edge,
            bitsPerComponent: 8,
            bytesPerRow: edge * 4,
            space: space,
            bitmapInfo: info
        )!
        let cgImage = context.makeImage()!
        return UIImage(cgImage: cgImage)
    }
}
