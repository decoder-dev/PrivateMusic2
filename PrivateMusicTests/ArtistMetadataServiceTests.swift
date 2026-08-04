import XCTest
@testable import PrivateMusic

final class ArtistMetadataServiceTests: XCTestCase {
    func testExactDeezerMatchOutranksPartialPrefix() {
        let exact = ArtistMetadataService.DeezerArtistCandidate(
            id: 1,
            name: "Queen",
            link: nil,
            pictureMedium: nil,
            pictureBig: nil,
            pictureXL: nil,
            nbAlbum: 10,
            nbFan: 100
        )
        let longer = ArtistMetadataService.DeezerArtistCandidate(
            id: 2,
            name: "Queen Latifah",
            link: nil,
            pictureMedium: nil,
            pictureBig: nil,
            pictureXL: nil,
            nbAlbum: 4,
            nbFan: 9_000_000
        )

        let best = ArtistMetadataService.bestMatch(
            in: [longer, exact],
            artist: "Queen"
        )

        XCTAssertEqual(best?.id, 1)
    }

    func testPartialNameDoesNotStealExactArtist() {
        XCTAssertEqual(
            ArtistMetadataService.matchScore(
                query: "Queen",
                candidate: "Queen Latifah"
            ),
            0
        )
        XCTAssertEqual(
            ArtistMetadataService.matchScore(
                query: "Queen",
                candidate: "Queen"
            ),
            100
        )
    }

    func testCollaborationCreditStillMatches() {
        XCTAssertEqual(
            ArtistMetadataService.matchScore(
                query: "Guest",
                candidate: "Host feat. Guest"
            ),
            80
        )
    }

    func testDeezerPayloadDecodingPrefersLargestArtwork() throws {
        let json = """
        {
          "data": [{
            "id": 27,
            "name": "Daft Punk",
            "link": "https://www.deezer.com/artist/27",
            "picture_medium": "https://cdn.example/m.jpg",
            "picture_big": "https://cdn.example/b.jpg",
            "picture_xl": "https://cdn.example/xl.jpg",
            "nb_album": 38,
            "nb_fan": 5000000
          }]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(
            ArtistMetadataService.DeezerArtistSearchResponse.self,
            from: json
        )
        let artist = try XCTUnwrap(response.data.first)

        XCTAssertEqual(artist.nbFan, 5_000_000)
        XCTAssertEqual(artist.nbAlbum, 38)
        XCTAssertEqual(
            artist.preferredArtworkURL?.absoluteString,
            "https://cdn.example/xl.jpg"
        )
    }

    func testWikipediaDisambiguationIsRejected() {
        let summary = ArtistMetadataService.WikipediaSummary(
            type: "disambiguation",
            title: "Queen",
            extract: "Queen may refer to…",
            thumbnailURL: nil,
            pageURL: nil
        )

        XCTAssertFalse(
            ArtistMetadataService.isUsableBiography(
                summary,
                artist: "Queen"
            )
        )
    }

    func testWikipediaStandardExtractIsAcceptedForMatchingTitle() {
        let summary = ArtistMetadataService.WikipediaSummary(
            type: "standard",
            title: "Daft Punk",
            extract: "French electronic duo.",
            thumbnailURL: nil,
            pageURL: nil
        )

        XCTAssertTrue(
            ArtistMetadataService.isUsableBiography(
                summary,
                artist: "Daft Punk"
            )
        )
    }

    func testPreferredWikipediaLanguagesPreferRussianFirst() {
        let locale = Locale(identifier: "ru_RU")
        XCTAssertEqual(
            ArtistMetadataService.preferredWikipediaLanguages(
                locale: locale
            ).prefix(2).map { $0 },
            ["ru", "en"]
        )
    }

    func testStatsLineJoinsFansAndAlbums() {
        let line = ArtistMetadataService.statsLine(
            fanCount: 1_200_000,
            albumCount: 12
        )

        XCTAssertNotNil(line)
        XCTAssertTrue(line?.contains("·") == true)
    }

    func testClippedBiographyStopsNearWordBoundary() {
        let text = String(repeating: "word ", count: 80)
        let clipped = ArtistMetadataService.clippedBiography(
            text,
            limit: 40
        )

        XCTAssertTrue(clipped.hasSuffix("…"))
        XCTAssertLessThanOrEqual(clipped.count, 44)
        XCTAssertFalse(clipped.contains("\n"))
    }

    func testEmptyArtistHasNoEnrichment() {
        let meta = ArtistExternalMetadata(name: "X")
        XCTAssertFalse(meta.hasEnrichment)
    }
}
