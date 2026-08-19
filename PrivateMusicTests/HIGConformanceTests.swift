import XCTest
@testable import PrivateMusic

final class HIGConformanceTests: XCTestCase {
    func testSystemTabViewMarksSearchWithTheSystemRole() {
        let source = SourceInspection.code(
            "PrivateMusic/Features/Root/MainTabView.swift"
        )
        XCTAssertTrue(source.contains("role: .search"))
        XCTAssertTrue(source.contains("value: MainTab.search"))
        XCTAssertFalse(source.contains("tabViewSearchActivation"))
    }

    func testPremiumCardsStayOnStandardMaterials() {
        let source = SourceInspection.code(
            "PrivateMusic/Features/Shared/PremiumDesign.swift"
        )
        XCTAssertTrue(source.contains("regularMaterial"))
        XCTAssertTrue(source.contains("colorSchemeContrast"))
        XCTAssertFalse(source.contains("glassEffect"))
    }

    func testHomeAndLibraryFollowDynamicType() {
        let home = SourceInspection.code(
            "PrivateMusic/Features/Catalog/CatalogView.swift"
        )
        let library = SourceInspection.code(
            "PrivateMusic/Features/Library/LibraryView.swift"
        )
        let tabs = SourceInspection.code(
            "PrivateMusic/Features/Root/MainTabView.swift"
        )
        let player = SourceInspection.code(
            "PrivateMusic/Features/Player/PlayerView.swift"
        )
        XCTAssertFalse(home.contains(".dynamicTypeSize(...DynamicTypeSize.large)"))
        XCTAssertFalse(
            library.contains(".dynamicTypeSize(...DynamicTypeSize.large)")
        )
        XCTAssertFalse(tabs.contains(".dynamicTypeSize(...DynamicTypeSize.large)"))
        XCTAssertFalse(
            player.contains(".dynamicTypeSize(...DynamicTypeSize.accessibility1)")
        )
    }

    func testCustomGlassFlattensUnderIncreaseContrast() {
        XCTAssertTrue(
            ContrastPolicy.flattensCustomGlass(
                reduceTransparency: false,
                increaseContrast: true,
                prefersClassicChrome: false
            )
        )
        XCTAssertTrue(
            ContrastPolicy.flattensCustomGlass(
                reduceTransparency: true,
                increaseContrast: false,
                prefersClassicChrome: false
            )
        )
        XCTAssertFalse(
            ContrastPolicy.flattensCustomGlass(
                reduceTransparency: false,
                increaseContrast: false,
                prefersClassicChrome: false
            )
        )
        XCTAssertGreaterThan(
            ContrastPolicy.strokeWidth(increased: true),
            ContrastPolicy.strokeWidth(increased: false)
        )
        XCTAssertGreaterThan(
            ContrastPolicy.strokeOpacity(increased: true, reduceTransparency: false),
            ContrastPolicy.strokeOpacity(increased: false, reduceTransparency: false)
        )
    }

    func testPlayerGlassFollowsContrastPolicy() {
        let player = SourceInspection.code(
            "PrivateMusic/Features/Player/PlayerView.swift"
        )
        XCTAssertTrue(player.contains("ContrastPolicy.flattensCustomGlass"))
        XCTAssertTrue(player.contains("colorSchemeContrast"))
        XCTAssertTrue(player.contains("guard !usesScrollingLayout"))
    }

    func testAccessibilityStepsCoverTheFiveDynamicTypeSizes() {
        XCTAssertEqual(PlayerAccessibilityPolicy.step(for: .large), 0)
        XCTAssertEqual(PlayerAccessibilityPolicy.step(for: .xxxLarge), 0)
        XCTAssertEqual(PlayerAccessibilityPolicy.step(for: .accessibility1), 1)
        XCTAssertEqual(PlayerAccessibilityPolicy.step(for: .accessibility5), 5)
    }

    func testDockRowGrowsForAccessibilityButIsAFloor() {
        XCTAssertEqual(
            PlaybackDockMetrics.tabRowMinHeight(isAccessibilitySize: false),
            48
        )
        XCTAssertEqual(
            PlaybackDockMetrics.tabRowMinHeight(isAccessibilitySize: true),
            68
        )
        XCTAssertGreaterThan(
            PlaybackDockMetrics.searchControlSize(isAccessibilitySize: true),
            PlaybackDockMetrics.searchControlSize(isAccessibilitySize: false)
        )
        let tabs = SourceInspection.code(
            "PrivateMusic/Features/Root/MainTabView.swift"
        )
        XCTAssertTrue(tabs.contains("frame(minHeight: tabRowHeight)"))
        XCTAssertFalse(tabs.contains(".frame(height: tabRowHeight)"))
    }

    func testSystemTextScaleDoesNotOverrideTheReader() {
        XCTAssertNil(AppTextScalePolicy.range(for: .system))
        XCTAssertNil(
            AppTextScalePolicy.resolvedRange(for: .system, inherited: .large)
        )
    }

    func testCompactTextScaleOnlyLowersTheCeiling() {
        let range = AppTextScalePolicy.range(for: .compact)
        XCTAssertEqual(range?.lowerBound, .xSmall)
        XCTAssertEqual(range?.upperBound, .medium)
        XCTAssertEqual(
            AppTextScalePolicy.resolvedRange(for: .compact, inherited: .large),
            range
        )
    }

    func testCompactTextScaleDoesNotClampAccessibilitySizes() {
        XCTAssertNil(
            AppTextScalePolicy.resolvedRange(
                for: .compact,
                inherited: .accessibility1
            )
        )
        XCTAssertNil(
            AppTextScalePolicy.resolvedRange(
                for: .compact,
                inherited: .accessibility5
            )
        )
        XCTAssertEqual(
            AppTextScalePolicy.resolvedRange(
                for: .large,
                inherited: .accessibility3
            ),
            nil
        )
    }

    func testLargerTextScalesRaiseTheFloorNotTheCeiling() {
        let large = AppTextScalePolicy.range(for: .large)
        XCTAssertEqual(large?.lowerBound, .xLarge)
        XCTAssertEqual(large?.upperBound, .accessibility5)

        let extra = AppTextScalePolicy.range(for: .extraLarge)
        XCTAssertEqual(extra?.lowerBound, .xxLarge)
        XCTAssertEqual(extra?.upperBound, .accessibility5)
    }

    func testCommentStrippingIgnoresLineComments() {
        let source = """
        // role: .search
        Tab(role: .search)
        """
        let code = SourceInspection.stripComments(from: source)
        XCTAssertTrue(code.contains("Tab(role: .search)"))
        XCTAssertFalse(code.contains("//"))
        XCTAssertEqual(code.components(separatedBy: "role: .search").count, 2)
    }
}
