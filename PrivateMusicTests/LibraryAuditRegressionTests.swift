import XCTest
@testable import PrivateMusic

@MainActor
final class LibraryAuditRegressionTests: XCTestCase {
    private func track(_ id: Int, owner: Int = 42) -> Track {
        Track(trackID: id, ownerID: owner, title: "Track \(id)", artist: "Artist",
              duration: 180, streamURL: nil, artworkURL: nil)
    }

    func testExplicitRemovalOverridesOwnerFallback() {
        let store = MusicLibraryStore()
        let own = track(1)
        XCTAssertTrue(store.isLiked(own, currentUserID: 42))
        store.markRemoved(own)
        XCTAssertFalse(store.isLiked(own, currentUserID: 42))
        store.markAdded(source: own, stored: own)
        XCTAssertTrue(store.isLiked(own, currentUserID: 42))
    }

    func testSynchronizedEmptyLibraryDoesNotLikeDeletedOwnedTracks() {
        let store = MusicLibraryStore()
        store.replace(with: [], refreshID: store.beginRefresh())
        XCTAssertFalse(store.isLiked(track(1), currentUserID: 42))
    }

    func testAccountSwitchClearsIndexAndRejectsLateRefresh() {
        let store = MusicLibraryStore()
        store.prepare(accountID: 42)
        let old = store.beginRefresh()
        store.include([track(1)])
        store.prepare(accountID: 99)
        XCTAssertFalse(store.contains(track(1)))
        XCTAssertNil(store.storedTrack(for: track(1)))
        store.replace(with: [track(1)], refreshID: old)
        XCTAssertTrue(store.signatures.isEmpty)
    }

    func testPreparingSameAccountKeepsIndexAndPendingRefresh() {
        let store = MusicLibraryStore()
        store.prepare(accountID: 42)
        let refresh = store.beginRefresh()
        store.prepare(accountID: 42)
        store.replace(with: [track(1)], refreshID: refresh)
        XCTAssertTrue(store.contains(track(1)))
    }

    func testDeletionReconcilesBoundaryWithoutSkippingTheNextTrack() async {
        let model = TrackCollectionViewModel(source: .library)
        await model.load {
            MusicPage(items: (1...100).map { self.track($0) }, totalCount: 200, nextOffset: 100)
        }
        model.removeLocally(track(1))
        var offsets: [Int] = []
        await model.loadAllForSearch { offset in
            offsets.append(offset)
            let server = Array(2...200)
            let end = min(offset + 100, server.count)
            return MusicPage(
                items: server[offset..<end].map { self.track($0) },
                totalCount: server.count,
                nextOffset: end < server.count ? end : nil
            )
        }
        XCTAssertEqual(offsets, [0, 100])
        XCTAssertEqual(model.tracks.map(\.trackID), Array(2...200))
        XCTAssertEqual(model.totalCount, 199)
    }

    func testSearchFetchesMatchesBeyondTheVisiblePage() async {
        let model = TrackCollectionViewModel(source: .library)
        await model.load {
            MusicPage(items: (1...100).map { self.track($0) }, totalCount: 200, nextOffset: 100)
        }
        await model.loadAllForSearch { offset in
            XCTAssertEqual(offset, 100)
            return MusicPage(items: (101...200).map { self.track($0) }, totalCount: 200, nextOffset: nil)
        }
        XCTAssertTrue(model.tracks.contains { $0.title == "Track 150" })
        XCTAssertNil(model.nextPageOffset)
    }

    func testSearchFailureKeepsMatchesAndCanRetryRemainingPage() async {
        let model = TrackCollectionViewModel(source: .library)
        await model.load { MusicPage(items: [self.track(1)], totalCount: 2, nextOffset: 1) }
        await model.loadAllForSearch { _ in throw APIError.timedOut }
        XCTAssertEqual(model.tracks.count, 1)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.nextPageOffset, 1)
        await model.loadAllForSearch { offset in
            XCTAssertEqual(offset, 1)
            return MusicPage(items: [self.track(2)], totalCount: 2, nextOffset: nil)
        }
        XCTAssertEqual(model.tracks.map(\.trackID), [1, 2])
        XCTAssertNil(model.errorMessage)
    }

    func testNonAdvancingServerCursorCannotLoopSearchForever() async {
        let model = TrackCollectionViewModel(source: .library)
        await model.load { MusicPage(items: [self.track(1)], totalCount: 2, nextOffset: 1) }
        var calls = 0
        await model.loadAllForSearch { _ in
            calls += 1
            return MusicPage(items: [], totalCount: 2, nextOffset: 1)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertNil(model.nextPageOffset)
    }

    func testFilteredQueueNeverUsesUnfilteredContinuation() {
        XCTAssertFalse(LibrarySearchPolicy.allowsContinuation(query: "Artist"))
        XCTAssertFalse(LibrarySearchPolicy.allowsContinuation(query: " Artist "))
        XCTAssertTrue(LibrarySearchPolicy.allowsContinuation(query: " \n "))
    }
}
