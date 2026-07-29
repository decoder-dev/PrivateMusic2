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
}
