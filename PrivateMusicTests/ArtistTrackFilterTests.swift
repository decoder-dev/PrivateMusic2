import XCTest
@testable import PrivateMusic

final class ArtistTrackFilterTests: XCTestCase {
    func testArtistRequestHasFiniteLoadingDeadline() {
        XCTAssertGreaterThan(ArtistLoadPolicy.timeout, 0)
        XCTAssertLessThanOrEqual(ArtistLoadPolicy.timeout, 30)
    }

    func testExactArtistMatchIsCaseAndDiacriticInsensitive() {
        XCTAssertTrue(
            ArtistTrackFilter.matches(
                "Beyoncé",
                artist: "BEYONCE"
            )
        )
    }

    func testCollaborationCreditsMatchWholeArtistComponents() {
        XCTAssertTrue(
            ArtistTrackFilter.matches(
                "Artist One feat. Artist Two",
                artist: "Artist Two"
            )
        )
        XCTAssertTrue(
            ArtistTrackFilter.matches(
                "Artist One, Artist Two",
                artist: "Artist One"
            )
        )
    }

    func testPartialNameDoesNotMatchAnotherArtist() {
        XCTAssertFalse(
            ArtistTrackFilter.matches(
                "Queen Latifah",
                artist: "Queen"
            )
        )
    }

    func testFilteredResultsKeepOrderAndRemoveDuplicateTracks() {
        let first = makeTrack(id: 1, artist: "Artist")
        let duplicate = makeTrack(id: 1, artist: "Artist")
        let unrelated = makeTrack(id: 2, artist: "Another Artist")
        let collaboration = makeTrack(
            id: 3,
            artist: "Artist feat. Guest"
        )

        let result = ArtistTrackFilter.filtered(
            [first, duplicate, unrelated, collaboration],
            artist: "Artist"
        )

        XCTAssertEqual(result.map(\.trackID), [1, 3])
    }

    private func makeTrack(id: Int, artist: String) -> Track {
        Track(
            trackID: id,
            ownerID: 1,
            title: "Track \(id)",
            artist: artist,
            duration: 180,
            streamURL: nil,
            artworkURL: nil
        )
    }
}
