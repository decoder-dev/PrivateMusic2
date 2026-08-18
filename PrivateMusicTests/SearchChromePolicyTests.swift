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
}
