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
}
