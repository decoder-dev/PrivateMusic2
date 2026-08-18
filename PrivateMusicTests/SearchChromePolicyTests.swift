import XCTest
@testable import PrivateMusic

final class SearchChromePolicyTests: XCTestCase {
    func testSystemSearchRequiresIOS26WithoutClassicChrome() {
        XCTAssertTrue(
            SearchChromePolicy.usesSystemSearchChrome(
                isIOS26OrLater: true,
                classicChrome: false
            )
        )
        XCTAssertFalse(
            SearchChromePolicy.usesSystemSearchChrome(
                isIOS26OrLater: true,
                classicChrome: true
            )
        )
        XCTAssertFalse(
            SearchChromePolicy.usesSystemSearchChrome(
                isIOS26OrLater: false,
                classicChrome: false
            )
        )
    }

    func testIOS26SearchTabUsesTheSemanticRoleNotBarActivation() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = (try? String(
            contentsOf: root
                .appendingPathComponent("PrivateMusic/Features/Root/MainTabView.swift"),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(source.contains("role: .search"))
        XCTAssertFalse(source.contains("tabViewSearchActivation"))
    }
}
