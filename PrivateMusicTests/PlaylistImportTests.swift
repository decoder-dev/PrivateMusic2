import XCTest
@testable import PrivateMusic

final class PlaylistImportTests: XCTestCase {
    private func track(_ id: Int, _ title: String, _ artist: String) -> Track {
        Track(
            trackID: id, ownerID: 1, title: title, artist: artist,
            duration: 200, streamURL: nil, artworkURL: nil
        )
    }

    func testPlainLinesAcceptSeparatorsNumberingAndTitlesOnly() {
        let text = """
        1. Скриптонит - Дома
        Monkey Majik — Around the World
          Just a title
        Queen – Bohemian Rhapsody (Remastered 2011)

        Скриптонит - Дома
        """
        let items = PlaylistImportParser.parse(text)
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items[0], .init(artist: "Скриптонит", title: "Дома"))
        XCTAssertEqual(items[2], .init(artist: "", title: "Just a title"))
    }

    func testCSVHandlesQuotesSemicolonsAndRussianHeaders() {
        let spotify = "Track URI,Track Name,Artist Name(s),Album Name\n"
            + "\"spotify:track:1\",\"Hello, World\",\"Band A;Band B\",\"Alb\"\n"
            + "\"spotify:track:2\",\"Say \"\"Hi\"\"\",AC/DC,x\n"
        XCTAssertEqual(PlaylistImportParser.parse(spotify), [
            .init(artist: "Band A, Band B", title: "Hello, World"),
            .init(artist: "AC/DC", title: "Say \"Hi\"")
        ])
        let russian = "\u{FEFF}Название,Исполнитель\r\nКукушка,Кино\r\nГруппа крови,Кино\r\n"
        XCTAssertEqual(PlaylistImportParser.parse(russian).count, 2)
    }

    func testCommasInOrdinaryLinesDoNotMakeATable() {
        XCTAssertEqual(PlaylistImportParser.parse("Hello, how are you - Band").count, 1)
    }

    func testImportIsCapped() {
        let many = (0..<700).map { "A\($0) - T\($0)" }.joined(separator: "\n")
        XCTAssertEqual(PlaylistImportParser.parse(many).count, PlaylistImportParser.maximumItems)
    }

    func testMatcherPrefersTheStudioVersionByTheRightArtist() {
        let item = PlaylistImportParser.Item(artist: "Queen", title: "Bohemian Rhapsody (Remastered 2011)")
        let hits = [
            track(1, "Bohemian Rhapsody", "Queen"),
            track(2, "Bohemian Rhapsody (Live)", "Queen"),
            track(3, "Bohemian Rhapsody", "Some Cover Band")
        ]
        let match = PlaylistImportMatcher.best(for: item, in: hits)
        XCTAssertEqual(match?.track.trackID, 1)
        XCTAssertEqual(match?.isConfident, true)
        XCTAssertNil(PlaylistImportMatcher.best(for: item, in: [hits[2]]))
        XCTAssertEqual(PlaylistImportMatcher.query(for: item), "Queen Bohemian Rhapsody")
    }

    func testMatcherToleratesFeaturedArtistsAndRejectsPartialTitles() {
        let item = PlaylistImportParser.Item(artist: "Скриптонит", title: "Дома")
        XCTAssertEqual(
            PlaylistImportMatcher.best(for: item, in: [track(9, "Дома", "Скриптонит, Niman")])?.track.trackID,
            9
        )
        XCTAssertEqual(
            PlaylistImportMatcher.best(for: item, in: [track(9, "Дома", "Скриптонит feat. 104")])?.track.trackID,
            9
        )
        let titleOnly = PlaylistImportParser.Item(artist: "", title: "Love")
        XCTAssertNil(PlaylistImportMatcher.best(for: titleOnly, in: [track(5, "Loveyourself", "Bieber")]))
    }
}
