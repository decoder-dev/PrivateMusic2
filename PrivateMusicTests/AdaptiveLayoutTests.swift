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

    /// Home is a hero, one What's Next and Recently Played now — the For You
    /// and VK Mixes shelves moved to the tabs that already own that content,
    /// so `HomeMetrics` dropped the recommendation card width and sizes only
    /// the What's Next artwork and the Recently Played rail.
    func testHomeMetricsPreservePhone390AndGrowOnIPad() {
        let phone = HomeMetrics(containerWidth: phoneWidth)
        let iPad = HomeMetrics(containerWidth: iPadWidth)

        XCTAssertEqual(phone.horizontalPadding, 16)
        XCTAssertEqual(phone.nextStepWidth, 70.2, accuracy: 0.01)
        XCTAssertEqual(phone.recentWidth, 126, accuracy: 0.01)

        XCTAssertEqual(iPad.horizontalPadding, 24)
        XCTAssertEqual(iPad.nextStepWidth, 76, accuracy: 0.01)
        XCTAssertEqual(iPad.recentWidth, 184.32, accuracy: 0.01)
        XCTAssertGreaterThan(iPad.nextStepWidth, phone.nextStepWidth)
        XCTAssertGreaterThan(iPad.recentWidth, phone.recentWidth)
    }

    /// The single What's Next row is a suggestion, not a second hero: its
    /// artwork stays inside the 64–76pt band and well under the Hero
    /// artwork at every width, including iPad where the rails grow.
    func testNextStepArtworkStaysWellUnderHeroArtwork() {
        for width in [CGFloat(320), 350, phoneWidth, 430, 744, iPadWidth] {
            let nextStep = HomeMetrics(containerWidth: width).nextStepWidth
            let hero = HomeStageMetrics.artworkSize(for: width)

            XCTAssertGreaterThanOrEqual(nextStep, 64)
            XCTAssertLessThanOrEqual(nextStep, 76)
            XCTAssertLessThan(nextStep, hero * 0.65)
        }
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
