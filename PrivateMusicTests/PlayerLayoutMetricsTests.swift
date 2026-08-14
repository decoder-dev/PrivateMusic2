import CoreGraphics
import XCTest
@testable import PrivateMusic

final class PlayerLayoutMetricsTests: XCTestCase {
    private static let shippedLocales = ["ru", "en"]

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

    func testQuickActionCaptionsFitFourColumnDockInShippedLocalizations() throws {
        for action in PlayerQuickAction.allCases {
            for locale in Self.shippedLocales {
                let title = try Self.localized(action.title, locale: locale)
                XCTAssertLessThanOrEqual(
                    title.count,
                    12,
                    "\(action) caption is too long for the player dock in \(locale)"
                )

                let accessibilityLabel = try Self.localized(
                    action.accessibilityLabel,
                    locale: locale
                )
                XCTAssertFalse(
                    accessibilityLabel.isEmpty,
                    "\(action) accessibility label is empty in \(locale)"
                )
            }
        }
    }

    func testMixRadioCompactTitlesStayShortForSegmentedPicker() throws {
        // Lookup by Russian keys — L10n may already resolve titles to English
        // on CI, so mode.compactTitle/title are not safe dictionary keys.
        let cases: [(mode: MixRadioMode, compactKey: String, titleKey: String)] = [
            (.balanced, "balanced", "balanced"),
            (.closerToSeed, "closer", "closer_to_track"),
            (.moreNovel, "novelty", "more_novelty"),
        ]
        for item in cases {
            for locale in Self.shippedLocales {
                let compactTitle = try Self.localized(
                    item.compactKey,
                    locale: locale
                )
                let title = try Self.localized(item.titleKey, locale: locale)
                XCTAssertLessThan(
                    compactTitle.count,
                    title.count + 1,
                    "\(item.mode) compact title is not shorter in \(locale)"
                )
                XCTAssertLessThanOrEqual(
                    compactTitle.count,
                    8,
                    "\(item.mode) compact title is too long in \(locale)"
                )
            }
        }

        XCTAssertEqual(
            try Self.localized("balanced", locale: "en"),
            "Balanced"
        )
        XCTAssertEqual(
            try Self.localized("balanced", locale: "en").count,
            8,
            "Balanced must remain within the segmented picker budget"
        )
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

    private static func localized(
        _ key: String,
        locale: String,
        filePath: String = #filePath
    ) throws -> String {
        let sourceRoot = URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = sourceRoot
            .appendingPathComponent("PrivateMusic")
            .appendingPathComponent("Resources")
            .appendingPathComponent("\(locale).lproj")
            .appendingPathComponent("Localizable.strings")
        let data = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.openStep
        let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        )
        guard let strings = plist as? [String: String] else {
            throw LocalizationFixtureError.invalidStringsFile(url.path)
        }
        guard let value = strings[key] else {
            throw LocalizationFixtureError.missingKey(key, locale)
        }
        return value
    }
}

private enum LocalizationFixtureError: Error, CustomStringConvertible {
    case invalidStringsFile(String)
    case missingKey(String, String)

    var description: String {
        switch self {
        case .invalidStringsFile(let path):
            return "Invalid strings file: \(path)"
        case .missingKey(let key, let locale):
            return "Missing \(locale) localization for \(key)"
        }
    }
}
