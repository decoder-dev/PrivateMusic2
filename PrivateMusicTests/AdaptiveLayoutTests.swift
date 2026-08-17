import CoreGraphics
import XCTest
@testable import PrivateMusic

final class AdaptiveLayoutTests: XCTestCase {
    private let phoneWidth: CGFloat = 390
    private let iPadWidth: CGFloat = 1024

    func testHorizontalPaddingMatchesPhoneAndIPadGutters() {
        XCTAssertEqual(AdaptiveLayout.horizontalPadding(for: 320), 14)
        XCTAssertEqual(AdaptiveLayout.horizontalPadding(for: 350), 14)
        XCTAssertEqual(AdaptiveLayout.horizontalPadding(for: phoneWidth), 16)
        XCTAssertEqual(AdaptiveLayout.horizontalPadding(for: iPadWidth), 24)
    }

    func testRegularWidthThresholdIsSevenHundred() {
        XCTAssertFalse(AdaptiveLayout.isRegularWidth(390))
        XCTAssertFalse(AdaptiveLayout.isRegularWidth(699))
        XCTAssertTrue(AdaptiveLayout.isRegularWidth(700))
        XCTAssertTrue(AdaptiveLayout.isRegularWidth(iPadWidth))
    }

    func testColumnCountStepsPhoneLargePhoneAndIPad() {
        XCTAssertEqual(AdaptiveLayout.columnCount(for: phoneWidth), 2)
        XCTAssertEqual(AdaptiveLayout.columnCount(for: 499), 2)
        XCTAssertEqual(AdaptiveLayout.columnCount(for: 500), 3)
        XCTAssertEqual(AdaptiveLayout.columnCount(for: 699), 3)
        XCTAssertEqual(AdaptiveLayout.columnCount(for: iPadWidth), 4)
    }

    func testShelfCardWidthGrowsOnIPadPastPhoneCap() {
        let phone = AdaptiveLayout.shelfCardWidth(
            for: phoneWidth,
            compactMax: 140,
            regularMax: 220,
            fraction: 0.35,
            compactMin: 112
        )
        let iPad = AdaptiveLayout.shelfCardWidth(
            for: iPadWidth,
            compactMax: 140,
            regularMax: 220,
            fraction: 0.35,
            compactMin: 112
        )

        XCTAssertEqual(phone, 136.5, accuracy: 0.01)
        XCTAssertGreaterThan(iPad, phone)
        XCTAssertGreaterThan(iPad, 140)
        XCTAssertEqual(iPad, 184.32, accuracy: 0.01)
        XCTAssertLessThanOrEqual(iPad, 220)
    }

    /// Home carries only its own discovery row now — the playlist and new
    /// release shelves moved to the Library and Mix tabs that already own
    /// that content, and `HomeMetrics` dropped the widths that existed
    /// only to size them.
    func testHomeMetricsPreservePhone390AndGrowOnIPad() {
        let phone = HomeMetrics(containerWidth: phoneWidth)
        let iPad = HomeMetrics(containerWidth: iPadWidth)

        XCTAssertEqual(phone.horizontalPadding, 16)
        XCTAssertEqual(phone.trackWidth, 140.4, accuracy: 0.01)
        XCTAssertEqual(phone.recentWidth, 126, accuracy: 0.01)

        XCTAssertEqual(iPad.horizontalPadding, 24)
        XCTAssertGreaterThan(iPad.trackWidth, phone.trackWidth)
        XCTAssertGreaterThan(iPad.recentWidth, phone.recentWidth)
    }

    func testMixHubMetricsPreservePhone390CardShareAndGrowOnIPad() {
        let phone = MixHubMetrics(width: phoneWidth)
        let iPad = MixHubMetrics(width: iPadWidth)

        XCTAssertEqual(phone.horizontalPadding, 16)
        XCTAssertEqual(phone.contentWidth, 358, accuracy: 0.01)
        XCTAssertEqual(phone.cardWidth, 358 * 0.38, accuracy: 0.01)
        XCTAssertEqual(phone.trackWidth, 140.4, accuracy: 0.01)
        XCTAssertEqual(phone.columnCount, 2)

        XCTAssertEqual(iPad.horizontalPadding, 24)
        XCTAssertGreaterThan(iPad.cardWidth, phone.cardWidth)
        XCTAssertGreaterThan(iPad.trackWidth, phone.trackWidth)
        XCTAssertEqual(iPad.columnCount, 4)
        XCTAssertLessThanOrEqual(iPad.cardWidth, 220)
    }

    func testLibraryShelfArtworkGrowsOnIPadFromPhoneBaseline() {
        let phoneArtwork = LibraryShelfMetrics.artworkSize(for: phoneWidth)
        let iPadArtwork = LibraryShelfMetrics.artworkSize(for: iPadWidth)

        XCTAssertEqual(phoneArtwork, LibraryShelfMetrics.artworkSize)
        XCTAssertEqual(
            LibraryShelfMetrics.cardWidth(for: phoneWidth),
            LibraryShelfMetrics.cardWidth
        )
        XCTAssertEqual(
            LibraryShelfMetrics.cardHeight(for: phoneWidth),
            LibraryShelfMetrics.cardHeight
        )
        XCTAssertEqual(
            LibraryShelfMetrics.shelfHeight(for: phoneWidth),
            LibraryShelfMetrics.shelfHeight
        )

        XCTAssertGreaterThan(iPadArtwork, phoneArtwork)
        XCTAssertGreaterThan(
            LibraryShelfMetrics.cardWidth(for: iPadWidth),
            LibraryShelfMetrics.cardWidth
        )
        XCTAssertEqual(iPadArtwork, 184.32, accuracy: 0.01)
    }
}
