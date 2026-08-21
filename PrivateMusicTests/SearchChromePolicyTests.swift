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
        let source = SourceInspection.code(
            "PrivateMusic/Features/Root/MainTabView.swift"
        )
        XCTAssertTrue(source.contains("role: .search"))
        XCTAssertFalse(source.contains("tabViewSearchActivation"))
    }
}
