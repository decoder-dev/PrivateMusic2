import XCTest
@testable import PrivateMusic

/// Pins the VK response shapes the app depends on. The audio methods are not
/// part of VK's public API, so a format drift should fail here in CI rather
/// than silently empty a screen on a user's phone.
final class VKResponseContractTests: XCTestCase {
    private func decodeItems(_ json: String) throws -> VKItems<Track> {
        try JSONDecoder().decode(
            VKResponse<VKItems<Track>>.self,
            from: Data(json.utf8)
        ).response
    }

    func testAudioGetPageDecodesTracksAndTotal() throws {
        let page = try decodeItems("""
        {"response":{"count":2,"items":[
          {"id":456239537,"owner_id":880122316,"artist":"Ksb music",
           "title":"Война","duration":187,"is_hq":1,
           "access_key":"abc123","lyrics_id":42,
           "album":{"id":7,"owner_id":880122316,"title":"Album"},
           "unknown_future_field":{"nested":[1,2,3]}},
          {"id":2,"owner_id":-2001,"artist":"A","title":"B"}
        ]}}
        """)
        XCTAssertEqual(page.count, 2)
        XCTAssertEqual(page.items.count, 2)
        let first = page.items[0]
        XCTAssertEqual(first.trackID, 456239537)
        XCTAssertEqual(first.ownerID, 880122316)
        XCTAssertEqual(first.title, "Война")
        XCTAssertEqual(first.artist, "Ksb music")
        XCTAssertEqual(first.duration, 187)
        XCTAssertEqual(first.albumTitle, "Album")
        XCTAssertEqual(first.accessKey, "abc123")
        XCTAssertEqual(first.lyricsID, 42)
        XCTAssertTrue(first.isHQ)
        XCTAssertEqual(page.items[1].ownerID, -2001)
        XCTAssertFalse(page.items[1].isHQ)
    }

    func testIsHQAcceptsIntegerAndBoolean() throws {
        for (raw, expected) in [("1", true), ("0", false), ("true", true), ("false", false)] {
            let page = try decodeItems(
                #"{"response":{"count":1,"items":[{"id":1,"owner_id":2,"artist":"a","title":"t","is_hq":\#(raw)}]}}"#
            )
            XCTAssertEqual(page.items.first?.isHQ, expected, "is_hq=\(raw)")
        }
    }

    func testMissingCountIsTolerated() throws {
        let page = try decodeItems(
            #"{"response":{"items":[{"id":1,"owner_id":2,"artist":"a","title":"t"}]}}"#
        )
        XCTAssertNil(page.count)
        XCTAssertEqual(page.items.count, 1)
    }

    func testEmptyPageDecodes() throws {
        let page = try decodeItems(#"{"response":{"count":0,"items":[]}}"#)
        XCTAssertTrue(page.items.isEmpty)
    }

    func testTrackWithInvalidIdentifiersIsRejected() {
        for body in [
            #"{"id":0,"owner_id":2,"artist":"a","title":"t"}"#,
            #"{"id":-5,"owner_id":2,"artist":"a","title":"t"}"#,
            #"{"id":1,"owner_id":0,"artist":"a","title":"t"}"#
        ] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(Track.self, from: Data(body.utf8)),
                body
            )
        }
    }

    func testTrackMissingRequiredFieldsIsRejected() {
        for body in [
            #"{"id":1,"owner_id":2,"artist":"a"}"#,
            #"{"id":1,"owner_id":2,"title":"t"}"#
        ] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(Track.self, from: Data(body.utf8)),
                body
            )
        }
    }

    func testTrackEncodeDecodeRoundTripKeepsIdentity() throws {
        let original = try JSONDecoder().decode(Track.self, from: Data(
            #"{"id":9,"owner_id":-3,"artist":"A","title":"T","duration":61,"access_key":"k"}"#.utf8
        ))
        let copy = try JSONDecoder().decode(
            Track.self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(copy.trackID, 9)
        XCTAssertEqual(copy.ownerID, -3)
        XCTAssertEqual(copy.duration, 61)
        XCTAssertEqual(copy.accessKey, "k")
    }
}
