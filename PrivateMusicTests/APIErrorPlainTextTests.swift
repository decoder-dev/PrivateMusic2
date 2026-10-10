import XCTest
@testable import PrivateMusic

final class APIErrorPlainTextTests: XCTestCase {
    func testKnownVKCodesGetPlainSentences() {
        for code in [5, 6, 9, 15, 201, 203] {
            let text = APIError.plainVKMessage(code: code, fallback: "Access denied")
            XCTAssertNotEqual(text, "Access denied", "code \(code)")
            XCTAssertFalse(text.isEmpty)
        }
    }

    func testEnglishFallbackNeverReachesTheUser() {
        let text = APIError.plainVKMessage(code: 77, fallback: "Internal server error")
        XCTAssertNotEqual(text, "Internal server error")
        XCTAssertTrue(text.contains("77"))
    }

    func testRussianTextFromOurOwnCodePathIsKept() {
        let own = "Лимит исчерпан"
        XCTAssertEqual(APIError.plainVKMessage(code: 77, fallback: own), own)
    }
}
