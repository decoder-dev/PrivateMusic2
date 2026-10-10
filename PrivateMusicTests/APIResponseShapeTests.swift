import XCTest
@testable import PrivateMusic

final class APIResponseShapeTests: XCTestCase {
    private func shape(_ json: String) throws -> [String: Any] {
        let text = try XCTUnwrap(APIResponseShape.skeleton(from: Data(json.utf8)))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
    }

    func testValuesAreReplacedByTypes() throws {
        let result = try shape(
            #"{"id":123,"title":"Secret title","url":"https://x/y?token=abc","is_hq":true,"gain":1.5,"none":null}"#
        )
        XCTAssertEqual(result["title"] as? String, "<string>")
        XCTAssertEqual(result["url"] as? String, "<string>")
        XCTAssertEqual(result["id"] as? Int, 0)
        XCTAssertEqual(result["is_hq"] as? Bool, true)
        XCTAssertEqual(result["gain"] as? Double, 0.5)
        XCTAssertTrue(result["none"] is NSNull)
    }

    func testOutputNeverContainsOriginalValues() throws {
        let text = try XCTUnwrap(APIResponseShape.skeleton(
            from: Data(#"{"response":{"items":[{"title":"Confidential","access_key":"k3y"}]}}"#.utf8)
        ))
        XCTAssertFalse(text.contains("Confidential"))
        XCTAssertFalse(text.contains("k3y"))
        XCTAssertTrue(text.contains("access_key"))
    }

    func testArraysAreCappedToTwoItems() throws {
        let result = try shape(#"{"items":[1,2,3,4,5]}"#)
        XCTAssertEqual((result["items"] as? [Any])?.count, APIResponseShape.maximumArrayItems)
    }

    func testInvalidJSONReturnsNil() {
        XCTAssertNil(APIResponseShape.skeleton(from: Data("<html>".utf8)))
    }

    func testLongOutputIsCapped() throws {
        let object = Dictionary(uniqueKeysWithValues: (0..<2000).map { ("key\($0)", 1) })
        let data = try JSONSerialization.data(withJSONObject: object)
        let text = try XCTUnwrap(APIResponseShape.skeleton(from: data))
        XCTAssertLessThanOrEqual(text.count, APIResponseShape.maximumLength + 1)
    }

    func testShapeLogLinesGetLargerBudgetThanOrdinaryLines() {
        let body = String(repeating: "a", count: 2_000)
        XCTAssertLessThan(AppLogRedaction.redact(body).count, 600)
        let line = "POST /method/audio.get shape={" + body + "}"
        XCTAssertGreaterThan(AppLogRedaction.redact(line).count, 1_500)
    }
}

final class SourceInspectionTests: XCTestCase {
    func testReadsRealSourceFiles() {
        let source = SourceInspection.source(
            "PrivateMusic/Core/Logging/APIResponseShape.swift"
        )
        XCTAssertTrue(source.contains("enum APIResponseShape"))
    }

    func testStripsCommentsButKeepsCode() {
        let code = SourceInspection.stripComments(
            from: "let a = 1 // role: .search\nlet b = 2\n"
        )
        XCTAssertFalse(code.contains("role"))
        XCTAssertTrue(code.contains("let b = 2"))
    }
}
