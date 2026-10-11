import XCTest
@testable import PrivateMusic

final class LRCLyricsServiceTests: XCTestCase {
    func testInvalidDurationsDoNotTrapOrEnterTheQuery() {
        for duration in [Double.nan, .infinity, -.infinity, -1, 0, Double(Int.max)] {
            XCTAssertNil(LRCLyricsService.durationQueryValue(duration))
        }
        XCTAssertEqual(LRCLyricsService.durationQueryValue(180.6), "181")
    }

    func testRepeatedTimestampsExpandAndDuplicatesAreRemoved() {
        let lines = LRCLyricsService.parseSynced("""
        [ar:Artist]
        [00:30.50][00:10.25] Chorus
        [00:10.25]Chorus
        [00:20]Verse
        """)
        XCTAssertEqual(lines.map(\.time), [10.25, 20, 30.5])
        XCTAssertEqual(lines.map(\.text), ["Chorus", "Verse", "Chorus"])
        XCTAssertEqual(Set(lines.map(\.id)).count, lines.count)
    }

    func testMalformedTimestampsCannotReachPlayback() {
        let lines = LRCLyricsService.parseSynced("""
        [-1:20]Negative
        [00:60]Invalid seconds
        [nan:00]Not a number
        [00:inf]Infinite
        [1e308:00]Overflow
        [00:10]
        [00:12.34]Valid
        """)
        XCTAssertEqual(lines, [LyricLine(time: 12.34, text: "Valid")])
    }
}
