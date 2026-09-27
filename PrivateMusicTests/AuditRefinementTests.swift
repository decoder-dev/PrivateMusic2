import XCTest
@testable import PrivateMusic

@MainActor
final class AuditRefinementTests: XCTestCase {
    private func track(_ id: Int) -> Track {
        Track(trackID: id, ownerID: 1, title: "Track \(id)", artist: "Artist", duration: 120, streamURL: nil, artworkURL: nil)
    }

    private func defaults() throws -> UserDefaults {
        let suite = "AuditRefinementTests.\(UUID().uuidString)"
        let value = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { value.removePersistentDomain(forName: suite) }
        return value
    }

    func testAccountSwitchPreservesOwnHistoryAndHidesPreviousAccount() throws {
        let preferences = try defaults()
        let history = ListeningHistoryStore(defaults: preferences, accountID: 10)
        history.record(track(1))
        history.configure(accountID: 20)
        XCTAssertTrue(history.entries.isEmpty)
        history.record(track(2))
        history.configure(accountID: 10)
        XCTAssertEqual(history.entries.map(\.track.trackID), [1])
        history.configure(accountID: nil)
        XCTAssertTrue(history.entries.isEmpty)
        let reopened = ListeningHistoryStore(defaults: preferences, accountID: 20)
        XCTAssertEqual(reopened.entries.map(\.track.trackID), [2])
    }

    func testDelayedSaveCannotWriteIntoNewAccount() async throws {
        let preferences = try defaults()
        let history = ListeningHistoryStore(defaults: preferences, accountID: 10)
        history.record(track(1))
        history.configure(accountID: 20)
        history.record(track(2))
        try await Task.sleep(for: .milliseconds(500))
        let first = ListeningHistoryStore(defaults: preferences, accountID: 10)
        let second = ListeningHistoryStore(defaults: preferences, accountID: 20)
        XCTAssertEqual(first.entries.map(\.track.trackID), [1])
        XCTAssertEqual(second.entries.map(\.track.trackID), [2])
    }

    func testUnownedLegacyHistoryIsPreservedButNotAssignedToAnAccount() throws {
        let preferences = try defaults()
        let legacy = try JSONEncoder().encode([ListeningHistoryEntry(track: track(1), playedAt: Date())])
        preferences.set(legacy, forKey: "listening.history.v1")
        let history = ListeningHistoryStore(defaults: preferences, accountID: 20)
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertEqual(preferences.data(forKey: "listening.history.v1"), legacy)
    }

    func testPinnedLongQueueRetainsCurrentTrackAndUpcomingTrack() {
        let tracks = (0..<200).map(track)
        let snapshot = PinnedMixSnapshot(mix: .common, tracks: tracks, currentIndex: 100, elapsed: 45)
        XCTAssertLessThanOrEqual(snapshot.tracks.count, MixTrackRequestPolicy.queueLimit)
        XCTAssertEqual(snapshot.tracks[snapshot.currentIndex].id, tracks[100].id)
        XCTAssertEqual(snapshot.tracks[snapshot.currentIndex + 1].id, tracks[101].id)
        XCTAssertEqual(snapshot.elapsed, 45)
    }

    func testPinnedTailRetainsItsActualTrackAndRejectsInvalidElapsed() {
        let tracks = (0..<200).map(track)
        let snapshot = PinnedMixSnapshot(mix: .common, tracks: tracks, currentIndex: 199, elapsed: .infinity)
        XCTAssertEqual(snapshot.tracks[snapshot.currentIndex].id, tracks[199].id)
        XCTAssertEqual(snapshot.elapsed, 0)
    }

    func testArtworkBucketsAreFiniteBoundedAndConsistent() {
        for input in [CGFloat.nan, .infinity, -.infinity, -.greatestFiniteMagnitude, .greatestFiniteMagnitude, 0, 1, 129] {
            let bucket = ArtworkDecodePolicy.pixelBucket(input)
            XCTAssertGreaterThanOrEqual(bucket, 128)
            XCTAssertLessThanOrEqual(bucket, 4096)
            XCTAssertEqual(bucket % 128, 0)
        }
        XCTAssertEqual(ArtworkDecodePolicy.pixelBucket(129), 256)
    }

    func testCorruptArtworkFailsDecoding() async {
        let bitmap = await ArtworkImageCache.downsample(Data("not an image".utf8), maxPixelSize: 128)
        XCTAssertNil(bitmap)
    }

    func testFailedEmptyCatalogDoesNotRetryOnEveryScreenAppear() {
        let catalog = HomeCatalogStore()
        let now = Date()
        let revision = catalog.beginRefreshing()
        catalog.finish(recommendations: nil, mixes: nil, errorMessage: "offline", refreshID: revision, now: now)
        XCTAssertFalse(catalog.shouldRefresh(force: false, now: now.addingTimeInterval(1)))
        XCTAssertTrue(catalog.shouldRefresh(force: true, now: now.addingTimeInterval(1)))
        XCTAssertTrue(catalog.shouldRefresh(force: false, now: now.addingTimeInterval(30)))
    }
}
