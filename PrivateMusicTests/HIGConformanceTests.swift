import XCTest
@testable import PrivateMusic

final class HIGConformanceTests: XCTestCase {
    func testSystemTabViewMarksSearchWithTheSystemRole() {
        let source = Self.source("PrivateMusic/Features/Root/MainTabView.swift")
        XCTAssertTrue(source.contains("role: .search"))
        XCTAssertTrue(source.contains("value: MainTab.search"))
        XCTAssertFalse(source.contains("tabViewSearchActivation"))
    }

    func testPremiumCardsStayOnStandardMaterials() {
        let source = Self.source(
            "PrivateMusic/Features/Shared/PremiumDesign.swift"
        )
        XCTAssertTrue(source.contains("regularMaterial"))
        XCTAssertTrue(source.contains("colorSchemeContrast"))
        XCTAssertFalse(source.contains("glassEffect"))
    }

    func testHomeAndLibraryFollowDynamicType() {
        let home = Self.source("PrivateMusic/Features/Catalog/CatalogView.swift")
        let library = Self.source(
            "PrivateMusic/Features/Library/LibraryView.swift"
        )
        XCTAssertFalse(home.contains(".dynamicTypeSize(...DynamicTypeSize.large)"))
        XCTAssertFalse(
            library.contains(".dynamicTypeSize(...DynamicTypeSize.large)")
        )
    }

    func testSystemTextScaleDoesNotOverrideTheReader() {
        XCTAssertNil(AppTextScalePolicy.range(for: .system))
    }

    func testCompactTextScaleOnlyLowersTheCeiling() {
        let range = AppTextScalePolicy.range(for: .compact)
        XCTAssertEqual(range?.lowerBound, .xSmall)
        XCTAssertEqual(range?.upperBound, .medium)
    }

    func testLargerTextScalesRaiseTheFloorNotTheCeiling() {
        let large = AppTextScalePolicy.range(for: .large)
        XCTAssertEqual(large?.lowerBound, .xLarge)
        XCTAssertEqual(large?.upperBound, .accessibility5)

        let extra = AppTextScalePolicy.range(for: .extraLarge)
        XCTAssertEqual(extra?.lowerBound, .xxLarge)
        XCTAssertEqual(extra?.upperBound, .accessibility5)
    }

    private static func source(
        _ relativePath: String,
        filePath: String = #filePath
    ) -> String {
        let root = URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(relativePath)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
