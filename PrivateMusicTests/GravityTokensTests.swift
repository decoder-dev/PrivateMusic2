import XCTest
@testable import PrivateMusic

final class GravityTokensTests: XCTestCase {
    func testBrandMatchesGravityActionYellow() {
        let source = Self.source("PrivateMusic/UI/Bubble/GravityTokens.swift")
        XCTAssertTrue(source.contains("#FFBE5C"))
        XCTAssertTrue(source.contains("#4CA0FF"))
        XCTAssertTrue(source.contains("190 / 255"))
        XCTAssertTrue(source.contains("92 / 255"))
        XCTAssertTrue(source.contains("76 / 255"))
        XCTAssertTrue(source.contains("160 / 255"))
    }

    func testRadiiMatchGravityControlAndLabel() {
        XCTAssertEqual(GravityTokens.labelRadius, 4)
        XCTAssertEqual(GravityTokens.controlRadius, 8)
    }

    func testHomeHeroUsesGravityActionPlayNotGlassCapsule() {
        let source = Self.source("PrivateMusic/Features/Catalog/HomeStageView.swift")
        XCTAssertTrue(source.contains("GravityActionButton("))
        XCTAssertFalse(source.contains("HomeStagePlayButton("))
        XCTAssertTrue(source.contains("BubbleIconButton("))
        XCTAssertTrue(source.contains("BubbleChip("))
    }

    func testHomeChipIsGravityLabelNotGlassCapsule() {
        let source = Self.source("PrivateMusic/UI/Bubble/BubbleComponents.swift")
        XCTAssertTrue(source.contains("GravityTokens.labelRadius"))
        XCTAssertTrue(source.contains("GravityTokens.labelFill"))
        XCTAssertFalse(source.contains("Capsule().fill(Material.ultraThin)"))
    }

    func testWhatsNextCardUsesGravitySurfaceAndAction() {
        let source = Self.source("PrivateMusic/Features/Catalog/CatalogView.swift")
        XCTAssertTrue(source.contains("GravityTokens.brand"))
        XCTAssertTrue(source.contains("GravityTokens.genericSurface"))
        XCTAssertTrue(source.contains("GravityTokens.controlRadius"))
        XCTAssertTrue(source.contains("GravityActionButton("))
        XCTAssertFalse(source.contains(".buttonStyle(.borderedProminent)"))
    }

    func testActionButtonKeepsBlackInkOnBrandFill() {
        let source = Self.source("PrivateMusic/UI/Bubble/GravityTokens.swift")
        XCTAssertTrue(source.contains(".foregroundStyle(.black)"))
        XCTAssertTrue(source.contains("GravityTokens.brand"))
        XCTAssertTrue(source.contains("controlRadius"))
    }

    func testPlayerAndTabsStayOffTheGravityTrial() {
        let player = Self.source("PrivateMusic/Features/Player/PlayerView.swift")
        let tabs = Self.source("PrivateMusic/Features/Root/MainTabView.swift")
        XCTAssertFalse(player.contains("GravityActionButton("))
        XCTAssertFalse(player.contains("GravityTokens."))
        XCTAssertFalse(tabs.contains("GravityActionButton("))
        XCTAssertFalse(tabs.contains("GravityTokens."))
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
