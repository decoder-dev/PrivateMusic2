import XCTest
@testable import PrivateMusic

@MainActor final class GeniusLyricsServiceTests: XCTestCase {
    func testSongAndMultiSearchResponsesBothDecodeAndSkipMalformedHits() throws {
        let hit = #"{"type":"song","result":{"title":"Song","url":"https://genius.com/Artist-song-lyrics","primary_artist":{"name":"Artist"}}}"#
        for payload in ["{\"hits\":[{}," + hit + "]}", "{\"sections\":[{}, {\"hits\":[" + hit + "]}]}"] {
            let data = Data(("{\"response\":" + payload + "}").utf8)
            let results = try GeniusLyricsService.searchCandidates(from: data)
            XCTAssertEqual(results.count, 1)
            XCTAssertEqual(results.first?.title, "Song")
        }
    }

    func testLookupFindsSongThroughSongEndpointThenExtractsPage() async throws {
        let service = GeniusLyricsService { url in
            if url.path == "/api/search/song" {
                return Data(#"{"response":{"hits":[{"type":"song","result":{"title":"Song","url":"https://genius.com/Artist-song-lyrics","primary_artist":{"name":"Artist"}}}]}}"#.utf8)
            }
            XCTAssertEqual(url.path, "/Artist-song-lyrics")
            return Data(#"<div data-lyrics-container="true">Verse<br>Chorus</div>"#.utf8)
        }
        let track = Track(trackID: 1, ownerID: 1, title: "Song", artist: "Artist", duration: 180, streamURL: nil, artworkURL: nil)
        let lyrics = try await service.lyrics(for: track)
        XCTAssertTrue(lyrics.text.contains("Verse"))
        XCTAssertTrue(lyrics.text.contains("Chorus"))
        XCTAssertEqual(lyrics.sourceURL?.path, "/Artist-song-lyrics")
    }

    func testBlockedLookupIsReportedAsAccessRestrictionInsteadOfMissingSong() async {
        let service = GeniusLyricsService { _ in throw GeniusLookupError.accessRestricted }
        let track = Track(trackID: 1, ownerID: 1, title: "Song", artist: "Artist", duration: 180, streamURL: nil, artworkURL: nil)
        do {
            _ = try await service.lyrics(for: track)
            XCTFail("Blocked lookup must not succeed")
        } catch is GeniusLookupError {
            // A browser action can recover this, unlike a genuine missing song.
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testChallengeAndErrorBodiesAreNotAcceptedAsLyrics() {
        XCTAssertFalse(GeniusResponsePolicy.isUsable("<title>Just a moment</title>", kind: .html))
        XCTAssertFalse(GeniusResponsePolicy.isUsable("<html>Artist lyrics unavailable</html>", kind: .html))
        XCTAssertFalse(GeniusResponsePolicy.isUsable("{\"message\":\"response unavailable\"}", kind: .json))
        XCTAssertTrue(GeniusResponsePolicy.isUsable("{\"response\":{\"sections\":[]}}", kind: .json))
        XCTAssertTrue(GeniusResponsePolicy.isUsable("<div data-lyrics-container=\"true\">Line</div>", kind: .html))
    }

    func testSongURLsRejectLookalikeHostsAndNonSongPages() {
        XCTAssertNil(GeniusResponsePolicy.songURL("https://evilgenius.com/song-lyrics"))
        XCTAssertNil(GeniusResponsePolicy.songURL("https://genius.com.attacker.test/song-lyrics"))
        XCTAssertNil(GeniusResponsePolicy.songURL("https://genius.com/artists/Artist"))
        XCTAssertNotNil(GeniusResponsePolicy.songURL("https://genius.com/Artist-song-lyrics?ref=search"))
    }

    func testParserKeepsEntitiesAndSkipsEmbeddedResources() throws {
        let html = """
        <div data-lyrics-container="true">Rock &amp; roll<br>\
        &quot;Hello&quot; &#x1F3B5;<img src="https://example.com/image.png">\
        <script>Not lyrics</script><style>Not lyrics either</style></div>
        """
        let result = try XCTUnwrap(GeniusLyricsService.extractLyrics(from: html))
        XCTAssertTrue(result.contains("Rock & roll"))
        XCTAssertTrue(result.contains("\"Hello\" 🎵"))
        XCTAssertFalse(result.contains("Not lyrics"))
        XCTAssertFalse(result.contains("example.com"))
    }

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

    // MARK: Matching

    private func candidate(_ title: String, _ artist: String) -> GeniusMatcher.Candidate {
        GeniusMatcher.Candidate(
            title: title,
            artist: artist,
            url: "https://genius.com/x-lyrics"
        )
    }

    func testAnotherSongBySameArtistIsRejected() {
        let match = GeniusMatcher.best(
            in: [candidate("Completely Different", "Artist")],
            artist: "Artist",
            title: "Wanted Song"
        )
        XCTAssertNil(match)
    }

    func testSameTitleByAnotherArtistIsRejected() {
        XCTAssertNil(GeniusMatcher.best(
            in: [candidate("Intro", "Somebody Else")],
            artist: "Artist",
            title: "Intro"
        ))
    }

    func testFeaturingAndRemasterNoiseDoesNotBreakTheMatch() {
        let match = GeniusMatcher.best(
            in: [candidate("Wanted Song", "Artist")],
            artist: "Artist feat. Guest",
            title: "Wanted Song (feat. Guest) - Remastered 2011"
        )
        XCTAssertNotNil(match)
    }

    func testTranslationPagesAreNeverChosen() {
        XCTAssertNil(GeniusMatcher.best(
            in: [candidate(
                "Wanted Song (Russian Translation)",
                "Genius Russian Translations"
            )],
            artist: "Artist",
            title: "Wanted Song"
        ))
    }

    func testRemixIsNotTheOriginal() {
        let original = candidate("Wanted Song", "Artist")
        let remix = candidate("Wanted Song (Sped Up)", "Artist")
        let best = GeniusMatcher.best(
            in: [remix, original],
            artist: "Artist",
            title: "Wanted Song"
        )
        XCTAssertEqual(best, original)
    }

    func testCyrillicTrackMatchesLatinGeniusPage() {
        XCTAssertNotNil(GeniusMatcher.best(
            in: [candidate("Kosmos", "Skryptonite")],
            artist: "Скриптонит",
            title: "Космос"
        ))
    }

    func testShortTitleDoesNotMatchInsideALongerOne() {
        XCTAssertNil(GeniusMatcher.best(
            in: [candidate("Love Yourself", "Artist")],
            artist: "Artist",
            title: "Love"
        ))
    }

    func testQueryUsesLeadArtistAndCleanTitle() {
        XCTAssertEqual(
            GeniusMatcher.searchQuery(
                artist: "Artist, Guest",
                title: "Wanted Song (feat. Guest) [Deluxe]"
            ),
            "Artist Wanted Song"
        )
    }

    func testLiveInsideAWordIsNotAVariant() {
        XCTAssertNotNil(GeniusMatcher.best(
            in: [candidate("Stayin' Alive", "Bee Gees")],
            artist: "Bee Gees",
            title: "Stayin' Alive"
        ))
        XCTAssertTrue(GeniusMatcher.variants(in: "Song (Live)").contains("live"))
        XCTAssertTrue(GeniusMatcher.variants(in: "Alive").isEmpty)
    }

    func testLoneRemixDoesNotPassForTheOriginal() {
        XCTAssertNil(GeniusMatcher.best(
            in: [candidate("Wanted Song (Remix)", "Artist")],
            artist: "Artist",
            title: "Wanted Song"
        ))
    }
}
