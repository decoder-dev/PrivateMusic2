import XCTest
@testable import PrivateMusic

final class GeniusLyricsServiceTests: XCTestCase {
    func testSearchURLKeepsArtistAndTitleAsOneQuery() throws {
        let track = Track(
            trackID: 1,
            ownerID: 2,
            title: "Song & Story",
            artist: "Artist Name",
            duration: 180,
            streamURL: nil,
            artworkURL: nil
        )

        let url = GeniusLyricsService.searchPageURL(for: track)
        let components = try XCTUnwrap(
            URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )
        )
        let query = components.queryItems?.first {
            $0.name == "q"
        }?.value

        XCTAssertEqual(url.host, "genius.com")
        XCTAssertEqual(query, "Artist Name Song & Story")
    }

    func testLyricsParserKeepsAllNestedContainersInOrder() throws {
        let html = """
        <html><body>
        <div data-lyrics-container="true">
        [Куплет 1]<br>Первая строка
        <div>Вторая строка<br>Третья строка</div>
        [Припев]<br>Четвёртая строка
        </div>
        <div class="Lyrics__Container" data-lyrics-container='true'>
        [Куплет 2]<br>Пятая строка<div>Шестая строка</div>
        </div>
        </body></html>
        """

        let lyrics = try XCTUnwrap(
            GeniusLyricsService.extractLyrics(from: html)
        )

        XCTAssertTrue(lyrics.contains("[Куплет 1]"))
        XCTAssertTrue(lyrics.contains("Третья строка"))
        XCTAssertTrue(lyrics.contains("[Припев]"))
        XCTAssertTrue(lyrics.contains("[Куплет 2]"))
        XCTAssertTrue(lyrics.contains("Шестая строка"))
        XCTAssertLessThan(
            try XCTUnwrap(lyrics.range(of: "[Куплет 1]")?.lowerBound),
            try XCTUnwrap(lyrics.range(of: "[Куплет 2]")?.lowerBound)
        )
    }

    func testLyricsParserSupportsLegacyContainerWithoutDataAttribute()
        throws {
        let html = """
        <html><body>
        <div class="lyrics">
        [Verse 1]<br>First line<br>Second line
        </div>
        </body></html>
        """

        let lyrics = try XCTUnwrap(
            GeniusLyricsService.extractLyrics(from: html)
        )

        XCTAssertTrue(lyrics.contains("[Verse 1]"))
        XCTAssertTrue(lyrics.contains("First line"))
        XCTAssertTrue(lyrics.contains("Second line"))
    }

    func testContainerMatchingTwoSelectorsIsNotParsedTwice() throws {
        let html = """
        <div class="Lyrics__Container" data-lyrics-container="true">
        Only once
        </div>
        """

        let lyrics = try XCTUnwrap(
            GeniusLyricsService.extractLyrics(from: html)
        )

        XCTAssertEqual(
            lyrics.components(separatedBy: "Only once").count - 1,
            1
        )
    }

    func testExactSongOutranksDifferentSongBySameArtist() {
        let exact = GeniusLyricsService.matchScore(
            trackArtist: "Artist",
            trackTitle: "Wanted Song",
            candidateArtist: "Artist",
            candidateTitle: "Wanted Song"
        )
        let wrongSong = GeniusLyricsService.matchScore(
            trackArtist: "Artist",
            trackTitle: "Wanted Song",
            candidateArtist: "Artist",
            candidateTitle: "Completely Different"
        )

        XCTAssertGreaterThan(exact, wrongSong)
    }
}
