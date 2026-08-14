import XCTest
@testable import PrivateMusic

final class MixQueueFilterTests: XCTestCase {
    func testLanguageFilter() {
        let russian = Track(
            trackID: 1,
            ownerID: 1,
            title: "Песня",
            artist: "Артист",
            duration: 100,
            streamURL: nil,
            artworkURL: nil
        )
        let english = Track(
            trackID: 2,
            ownerID: 1,
            title: "Song",
            artist: "Artist",
            duration: 100,
            streamURL: nil,
            artworkURL: nil
        )
        XCTAssertTrue(
            MixQueueFilter.matchesLanguage(russian, preference: .russian)
        )
        XCTAssertFalse(
            MixQueueFilter.matchesLanguage(english, preference: .russian)
        )
        XCTAssertTrue(
            MixQueueFilter.matchesLanguage(english, preference: .foreign)
        )
    }

    func testFamiliarityFilter() {
        let known = Track(
            trackID: 1,
            ownerID: 1,
            title: "A",
            artist: "Alpha",
            duration: 100,
            streamURL: nil,
            artworkURL: nil
        )
        let novel = Track(
            trackID: 2,
            ownerID: 1,
            title: "B",
            artist: "Zeta",
            duration: 100,
            streamURL: nil,
            artworkURL: nil
        )
        let history: Set<String> = ["alpha"]
        XCTAssertTrue(
            MixQueueFilter.matchesFamiliarity(
                known,
                preference: .hits,
                historyArtists: history
            )
        )
        XCTAssertTrue(
            MixQueueFilter.matchesFamiliarity(
                novel,
                preference: .obscure,
                historyArtists: history
            )
        )
    }

    func testMoodShelfMatch() {
        XCTAssertTrue(
            MixQueueFilter.shelfMatchesMood(
                "Спокойный вечер",
                mood: .calm
            )
        )
        XCTAssertFalse(
            MixQueueFilter.shelfMatchesMood(
                "new_releases",
                mood: .love
            )
        )
    }
}

final class SnippetPreviewPolicyTests: XCTestCase {
    func testStartOffsetStaysInsideTrack() {
        let start = SnippetPreviewPolicy.startOffset(for: 200)
        XCTAssertGreaterThan(start, 0)
        XCTAssertLessThanOrEqual(
            start + SnippetPreviewPolicy.windowSeconds,
            200
        )
    }

    func testShortTrackStartsAtZero() {
        XCTAssertEqual(SnippetPreviewPolicy.startOffset(for: 10), 0)
    }
}

@MainActor
final class MixFeedbackStoreUnbanTests: XCTestCase {
    func testUnbanTrackAndArtist() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = MixFeedbackStore(defaults: defaults)
        store.configure(accountID: 42)
        let track = Track(
            trackID: 7,
            ownerID: 1,
            title: "Song",
            artist: "Alpha",
            duration: 100,
            streamURL: nil,
            artworkURL: nil
        )
        store.ban(track, includeArtist: true)
        XCTAssertTrue(store.isBanned(track))
        store.unbanTrack(id: track.id)
        XCTAssertFalse(store.bannedTrackIDs.contains(track.id))
        XCTAssertTrue(store.bannedArtists.contains("alpha"))
        store.unbanArtist(key: "Alpha")
        XCTAssertTrue(store.bannedArtistRecords.isEmpty)
    }
}
