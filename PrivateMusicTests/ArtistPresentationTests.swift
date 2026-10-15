import XCTest
@testable import PrivateMusic

final class ArtistPresentationTests: XCTestCase {
    func testMonogramsKeepShortStageNamesAndUnicodeInitials() {
        XCTAssertEqual(ArtistArtworkPolicy.initials(for: "ATL"), "ATL")
        XCTAssertEqual(ArtistArtworkPolicy.initials(for: "ЛСП"), "ЛСП")
        XCTAssertEqual(ArtistArtworkPolicy.initials(for: "  Монеточка  "), "МО")
        XCTAssertEqual(ArtistArtworkPolicy.initials(for: "Кино — Группа"), "КГ")
        XCTAssertEqual(ArtistArtworkPolicy.initials(for: "Björk"), "BJ")
    }

    func testMissingOrSymbolOnlyNamesUseThePersonFallback() {
        for name in ["", "  ", "—", "🎃"] {
            XCTAssertTrue(ArtistArtworkPolicy.initials(for: name).isEmpty)
        }
    }

    func testAlbumCoversAreNeverPresentedAsArtistPortraits() {
        let url = URL(string: "https://example.com/cover.jpg")!
        XCTAssertNil(ArtistArtworkPolicy.portraitURL(for: nil))
        XCTAssertNil(ArtistArtworkPolicy.portraitURL(for: VKArtist(id: "1", name: "ATL",
                                                               photoURL: url, isAlbumCover: true)))
        XCTAssertEqual(ArtistArtworkPolicy.portraitURL(for: VKArtist(id: "1", name: "ATL", photoURL: url)), url)
    }

    func testArtistQueueIdentitySurvivesPersistenceAndHasItsOwnCaption() throws {
        let source = QueueSource.artist(name: "Кино")
        let data = try JSONEncoder().encode(source)
        XCTAssertEqual(try JSONDecoder().decode(QueueSource.self, from: data), source)
        XCTAssertNil(source.mixID)
        XCTAssertEqual(QueueContextTitlePolicy.resolve(queueSource: source, queueSeedTrackTitle: "Песня"), "Кино")
        XCTAssertEqual(QueueSourcePlaybackAction.resolve(target: source, isPlaying: true,
                                                        queueSource: .artistMix(named: "Кино", title: "Кино")), .start)
        XCTAssertEqual(QueueSourcePlaybackAction.resolve(target: source, isPlaying: false, queueSource: source), .resume)
    }
}

@MainActor
final class ArtistCollectionPlaybackTests: XCTestCase {
    func testArtistCollectionDoesNotApplyRadioBansOrRanking() {
        let suite = "ArtistCollectionPlaybackTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: defaults)
        let player = AudioPlayer(settings: settings, historyStore: ListeningHistoryStore(defaults: defaults), defaults: defaults)
        defer { player.stop(); defaults.removePersistentDomain(forName: suite) }
        let tracks = (1...4).map { Track(trackID: $0, ownerID: 1, title: "Трек \($0)", artist: "ATL",
                                        duration: 180, streamURL: nil, artworkURL: nil) }
        var filterCalls = 0
        player.configureMixTrackFilter { _ in filterCalls += 1; return [] }
        player.play(tracks[0], in: tracks, source: .artist(name: "ATL"), allowsContinuation: false)
        XCTAssertEqual(filterCalls, 0)
        XCTAssertEqual(player.queue.map(\.id), tracks.map(\.id))
        XCTAssertEqual(player.highlight.queueSource, .artist(name: "ATL"))
    }
}
