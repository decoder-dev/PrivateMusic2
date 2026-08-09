import CoreGraphics
import XCTest
@testable import PrivateMusic

final class PlayerLayoutMetricsTests: XCTestCase {
    func testPortraitMetricsFitReferencePhoneSizes() {
        let sizes = [
            CGSize(width: 320, height: 568),
            CGSize(width: 375, height: 667),
            CGSize(width: 390, height: 844),
            CGSize(width: 430, height: 932),
        ]

        for size in sizes {
            let metrics = PlayerLayoutMetrics.resolve(
                containerSize: size,
                safeBottom: 34
            )

            XCTAssertNotEqual(
                metrics.mode,
                .landscape,
                "Unexpected landscape layout at \(size)"
            )
            XCTAssertLessThanOrEqual(
                metrics.minimumContentHeight,
                size.height,
                "Player content clips at \(size)"
            )
            XCTAssertGreaterThanOrEqual(
                metrics.artworkSize,
                112,
                "Artwork becomes unusably small at \(size)"
            )
            XCTAssertGreaterThanOrEqual(
                metrics.bottomPadding,
                34,
                "Controls overlap the home indicator at \(size)"
            )
        }
    }

    func testLandscapeMetricsFitReferenceSizesAndSafeAreas() {
        let sizes = [
            CGSize(width: 568, height: 320),
            CGSize(width: 667, height: 375),
            CGSize(width: 844, height: 390),
            CGSize(width: 932, height: 430),
        ]

        for size in sizes {
            let metrics = PlayerLayoutMetrics.resolve(
                containerSize: size,
                safeBottom: 21,
                safeLeading: 44,
                safeTrailing: 44
            )

            XCTAssertEqual(
                metrics.mode,
                .landscape,
                "Expected landscape layout at \(size)"
            )
            XCTAssertLessThanOrEqual(
                metrics.minimumContentHeight,
                size.height,
                "Landscape player content clips at \(size)"
            )
            XCTAssertGreaterThanOrEqual(
                metrics.leadingPadding,
                52,
                "Leading controls enter the unsafe region at \(size)"
            )
            XCTAssertGreaterThanOrEqual(
                metrics.trailingPadding,
                52,
                "Trailing controls enter the unsafe region at \(size)"
            )
            XCTAssertGreaterThanOrEqual(
                metrics.artworkSize,
                112,
                "Landscape artwork becomes unusably small at \(size)"
            )
        }
    }

    func testQuickActionsStayAboveBottomSafeArea() {
        let height: CGFloat = 844
        let safeBottom: CGFloat = 34
        let metrics = PlayerLayoutMetrics.resolve(
            containerSize: CGSize(width: 390, height: height),
            safeBottom: safeBottom
        )

        XCTAssertLessThanOrEqual(
            metrics.quickActionsBottomY(containerHeight: height),
            height - safeBottom
        )
    }

    func testAccessibilityQuickActionsKeepPreviousCompactDock() {
        let metrics = PlayerLayoutMetrics.resolve(
            containerSize: CGSize(width: 320, height: 568),
            safeBottom: 34,
            usesAccessibilityText: true
        )

        XCTAssertEqual(metrics.quickActionsHeight, 72)
        XCTAssertLessThanOrEqual(metrics.minimumContentHeight, 568)
        XCTAssertGreaterThanOrEqual(metrics.artworkSize, 0)
    }

    func testAccessibilityLandscapeKeepsPreviousTwoColumnLayout() {
        let metrics = PlayerLayoutMetrics.resolve(
            containerSize: CGSize(width: 568, height: 320),
            safeBottom: 21,
            safeLeading: 44,
            safeTrailing: 44,
            usesAccessibilityText: true
        )

        XCTAssertEqual(metrics.mode, .landscape)
        XCTAssertEqual(metrics.quickActionsHeight, 72)
        XCTAssertTrue(
            metrics.requiresAccessibilityScrolling(containerHeight: 320)
        )
    }

    func testPlayerControlsUseAccessibleMinimumHeights() {
        let metrics = PlayerLayoutMetrics.resolve(
            containerSize: CGSize(width: 320, height: 568),
            safeBottom: 34
        )

        XCTAssertGreaterThanOrEqual(metrics.headerHeight, 44)
        XCTAssertGreaterThanOrEqual(metrics.primaryControlsHeight, 44)
        XCTAssertGreaterThanOrEqual(metrics.quickActionsHeight, 44)
    }

    func testHeaderTitleInsetClearsSideControlCluster() {
        XCTAssertEqual(PlayerHeaderMetrics.sideClusterWidth, 96)
        XCTAssertGreaterThanOrEqual(
            PlayerHeaderMetrics.titleHorizontalInset,
            PlayerHeaderMetrics.sideClusterWidth
        )
    }

    func testQuickActionShareCaptionFitsFourColumnDock() {
        XCTAssertEqual(PlayerQuickAction.share.title, "Поделиться")
        XCTAssertEqual(
            PlayerQuickAction.share.accessibilityLabel,
            "Поделиться файлом"
        )
        for action in PlayerQuickAction.allCases {
            XCTAssertLessThanOrEqual(
                action.title.count,
                12,
                "\(action) caption is too long for the player dock"
            )
        }
    }

    func testMixRadioCompactTitlesStayShortForSegmentedPicker() {
        XCTAssertEqual(MixRadioMode.balanced.compactTitle, "Баланс")
        XCTAssertEqual(MixRadioMode.closerToSeed.compactTitle, "Ближе")
        XCTAssertEqual(MixRadioMode.moreNovel.compactTitle, "Новизна")
        for mode in MixRadioMode.allCases {
            XCTAssertLessThan(
                mode.compactTitle.count,
                mode.title.count + 1
            )
            XCTAssertLessThanOrEqual(mode.compactTitle.count, 8)
        }
    }

    func testPortraitMetricsDoNotJumpAtLayoutModeBoundaries() {
        for boundary in [720.0, 860.0] {
            let before = PlayerLayoutMetrics.resolve(
                containerSize: CGSize(width: 390, height: boundary - 0.5),
                safeBottom: 34
            )
            let after = PlayerLayoutMetrics.resolve(
                containerSize: CGSize(width: 390, height: boundary + 0.5),
                safeBottom: 34
            )

            XCTAssertLessThan(
                abs(after.artworkSize - before.artworkSize),
                2,
                "Artwork jumps around height \(boundary)"
            )
            XCTAssertLessThan(
                abs(after.leadingPadding - before.leadingPadding),
                1,
                "Horizontal padding jumps around height \(boundary)"
            )
            XCTAssertLessThan(
                abs(after.artworkTopSpacing - before.artworkTopSpacing),
                1,
                "Vertical spacing jumps around height \(boundary)"
            )
        }
    }
}
