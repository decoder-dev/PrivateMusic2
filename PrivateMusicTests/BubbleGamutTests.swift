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
    func testSmallColourSamplePreservesLargeCoverColoursAndTransparency() throws {
        for transparent in [false, true] {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512)).image { context in
                if !transparent {
                    UIColor.red.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 256, height: 512))
                }
                UIColor.blue.setFill()
                context.fill(CGRect(x: 256, y: 0, width: 256, height: 512))
            }
            let tint = try XCTUnwrap(BubbleArtworkTint.extract(from: image))
            XCTAssertLessThan(tint.green, 0.05)
            if transparent {
                XCTAssertGreaterThan(tint.blue, 0.9)
                XCTAssertLessThan(tint.red, 0.05)
            } else {
                XCTAssertEqual(tint.red, 0.5, accuracy: 0.1)
                XCTAssertEqual(tint.blue, 0.5, accuracy: 0.1)
            }
        }
    }

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
