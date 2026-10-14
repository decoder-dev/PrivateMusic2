import XCTest
@testable import PrivateMusic

final class LRCLyricsServiceTests: XCTestCase {
    private func track(duration: Double = 180) -> Track {
        Track(trackID: 1, ownerID: 1, title: "Song (feat. Guest) - Remastered 2020",
              artist: "Artist, Guest", albumTitle: "Album", duration: duration,
              streamURL: nil, artworkURL: nil)
    }

    func testLookupUsesExactMetadataThenCleanSearchWithoutUnsupportedDuration() throws {
        let urls = LRCLyricsService.lookupURLs(for: track())
        XCTAssertEqual(urls.map(\.path), ["/api/get", "/api/search", "/api/search"])
        let items = try XCTUnwrap(URLComponents(url: urls[1], resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "track_name" }?.value, "Song")
        XCTAssertEqual(items.first { $0.name == "artist_name" }?.value, "Artist")
        XCTAssertFalse(items.contains { $0.name == "duration" })
    }

    func testClosestDurationCannotSelectAnotherArtistOrSong() {
        let candidates = [
            LRCLyricsCandidate(trackName: "Different", artistName: "Artist", duration: 180, plainLyrics: "Wrong song", syncedLyrics: nil),
            LRCLyricsCandidate(trackName: "Song", artistName: "Other", duration: 180, plainLyrics: "Wrong artist", syncedLyrics: nil),
            LRCLyricsCandidate(trackName: "Song", artistName: "Artist", duration: 182, plainLyrics: "Right", syncedLyrics: "[00:10]Right")
        ]
        let lyrics = LRCLyricsService.bestLyrics(in: candidates, for: track())
        XCTAssertEqual(lyrics?.text, "Right")
        XCTAssertEqual(lyrics?.lines.count, 1)
    }

    func testEditedRecordingKeepsWordsButDoesNotUseMismatchedTimeline() {
        let candidate = LRCLyricsCandidate(trackName: "Song", artistName: "Artist", duration: 240,
                                          plainLyrics: "Words", syncedLyrics: "[00:10]Words")
        let lyrics = LRCLyricsService.bestLyrics(in: [candidate], for: track())
        XCTAssertEqual(lyrics?.text, "Words")
        XCTAssertTrue(lyrics?.lines.isEmpty == true)
    }

    func testMalformedRowDoesNotDiscardOtherSearchResults() throws {
        let data = Data(#"[{"trackName":"Broken"},{"trackName":"Song","artistName":"Artist","duration":180,"plainLyrics":"Words"}]"#.utf8)
        let candidates = try LRCLyricsService.decodeCandidates(data)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(LRCLyricsService.bestLyrics(in: candidates, for: track())?.text, "Words")
    }

    func testEmptyExactLookupFallsBackToSearchAndPreservesSyncedLyrics() async throws {
        let service = LRCLyricsService { url in
            if url.path == "/api/get" { return Data(#"{"trackName":"Song","artistName":"Artist","duration":180,"plainLyrics":null}"#.utf8) }
            return Data(#"[{"trackName":"Song","artistName":"Artist","duration":180,"syncedLyrics":"[00:10]Verse"}]"#.utf8)
        }
        let lyrics = try await service.lyrics(for: track())
        XCTAssertEqual(lyrics.text, "Verse")
        XCTAssertEqual(lyrics.lines.first?.time, 10)
    }

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
