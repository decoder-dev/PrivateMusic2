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

    func testMoodShelfMatchHandlesDecomposedY() {
        // "й" may be represented as "и" + combining breve (U+0306).
        // When that happens, diacritic-insensitive folding can
        // effectively erase the breve and break substring matching for
        // mood markers that include "й".
        let decomposedY = "и\u{0306}"
        XCTAssertTrue(
            MixQueueFilter.shelfMatchesMood(
                "Споко" + decomposedY,
                mood: .calm
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

final class MixFilterQueueWiringTests: XCTestCase {
    /// Language/familiarity must ride the same pipe as bans into the
    /// live mix queue — not a ban-only filter that leaves chip changes
    /// looking like they "do nothing".
    func testPlayerMixFilterUsesFullFilteredMixTracks() {
        let source = SourceInspection.code(
            "PrivateMusic/App/AppEnvironment.swift"
        )
        XCTAssertTrue(source.contains("configureMixTrackFilter"))
        XCTAssertTrue(source.contains("filteredMixTracks(tracks)"))
        XCTAssertTrue(source.contains("reapplyMixFiltersToPlayingQueue"))
    }

    func testHubRefilterSyncsPlayingQueue() {
        let source = SourceInspection.code(
            "PrivateMusic/Features/Mix/MixesHubView.swift"
        )
        XCTAssertTrue(source.contains("syncPlayingQueue(with:"))
        XCTAssertTrue(source.contains("currentMixForFilters"))
        XCTAssertTrue(source.contains("player.isPlaying(mix)"))
        XCTAssertTrue(source.contains("mixID"))
    }

    func testQueueSourceMixCarriesStableID() {
        let mix = MusicMix.common
        let source = QueueSource.catalogMix(mix)
        XCTAssertEqual(source.mixID, mix.id)
        XCTAssertEqual(source.mixTitle, mix.title)
        XCTAssertEqual(
            QueueSource.myMusicMix(title: "x").mixID,
            MixQueueIdentity.myMusic
        )
    }

    func testEnvironmentOwnsSharedSelenaExposure() {
        let source = SourceInspection.code(
            "PrivateMusic/App/AppEnvironment.swift"
        )
        XCTAssertTrue(source.contains("recordSelenaExposure"))
        XCTAssertTrue(source.contains("resetSelenaExposure"))
        XCTAssertTrue(source.contains("SelenaBanditPolicy.rerank"))
        XCTAssertTrue(source.contains("refreshHomeCatalog()"))
    }
}
