import XCTest
@testable import PrivateMusic

@MainActor
final class MusicLibraryStoreTests: XCTestCase {
    func testMatchesCopiedVKTrackByMetadata() {
        let store = MusicLibraryStore()
        let source = track(id: 1, owner: 20, title: "Ёлка")
        let stored = track(id: 99, owner: 42, title: "елка")

        store.markAdded(source: source, stored: stored)

        XCTAssertTrue(store.contains(source))
        XCTAssertTrue(store.contains(stored))
        XCTAssertEqual(store.storedTrack(for: source)?.id, stored.id)
    }

    func testRemovalClearsSignature() {
        let store = MusicLibraryStore()
        let value = track(id: 1, owner: 42, title: "Track")
        let refreshID = store.beginRefresh()
        store.replace(with: [value], refreshID: refreshID)

        store.markRemoved(value)

        XCTAssertFalse(store.contains(value))
    }

    func testLikedStateIncludesTracksOwnedByCurrentUser() {
        let store = MusicLibraryStore()
        let ownTrack = track(id: 1, owner: 42, title: "Own")
        let otherTrack = track(id: 2, owner: 20, title: "Other")

        XCTAssertTrue(store.isLiked(ownTrack, currentUserID: 42))
        XCTAssertFalse(store.isLiked(otherTrack, currentUserID: 42))
        let refreshID = store.beginRefresh()
        store.replace(with: [otherTrack], refreshID: refreshID)
        XCTAssertTrue(store.isLiked(otherTrack, currentUserID: 42))
    }

    func testStaleEmptyReplaceCannotWipeNewerIndex() {
        let store = MusicLibraryStore()
        let staleID = store.beginRefresh()
        let freshID = store.beginRefresh()
        store.replace(
            with: [track(id: 1, owner: 42, title: "Keep")],
            refreshID: freshID
        )

        store.replace(with: [], refreshID: staleID)

        XCTAssertEqual(store.signatures.count, 1)
    }

    // Медиатека shows the opening pages of the same audio.get walk. It used
    // to `replace` the index from there, so a 1000-track index shrank to 100
    // and every track below that lost its heart.
    func testIncludingAPageNeverShrinksTheIndex() {
        let store = MusicLibraryStore()
        let full = (1...4).map { track(id: $0, owner: 42, title: "T\($0)") }
        let refreshID = store.beginRefresh()
        store.replace(with: full, refreshID: refreshID)

        store.include([track(id: 1, owner: 42, title: "T1")])

        XCTAssertEqual(store.signatures.count, 4)
        XCTAssertTrue(store.contains(track(id: 4, owner: 42, title: "T4")))
    }

    func testIncludingAPageAddsTracksTheIndexHasNotSeen() {
        let store = MusicLibraryStore()
        let refreshID = store.beginRefresh()
        store.replace(
            with: [track(id: 1, owner: 42, title: "Known")],
            refreshID: refreshID
        )
        let fresh = track(id: 2, owner: 42, title: "New")

        store.include([fresh])

        XCTAssertTrue(store.contains(fresh))
        XCTAssertEqual(store.storedTrack(for: fresh)?.id, fresh.id)
    }

    // VK keeps serving an unliked track for a moment, so the page that was
    // already in flight when the user tapped the heart still contains it.
    func testIncludingDoesNotResurrectARemovedTrack() {
        let store = MusicLibraryStore()
        let removed = track(id: 1, owner: 42, title: "Gone")
        store.include([removed])
        store.markRemoved(removed)

        store.include([removed, track(id: 2, owner: 42, title: "Kept")])

        XCTAssertFalse(store.contains(removed))
        XCTAssertTrue(store.contains(track(id: 2, owner: 42, title: "Kept")))
    }

    func testALaterFullWalkCanBringBackARemovedTrack() {
        let store = MusicLibraryStore()
        let value = track(id: 1, owner: 42, title: "Gone")
        store.markRemoved(value)

        // Liking it again elsewhere makes the next authoritative walk the
        // truth — the tombstone must not outlive it.
        let refreshID = store.beginRefresh()
        store.replace(with: [value], refreshID: refreshID)
        store.include([value])

        XCTAssertTrue(store.contains(value))
    }

    func testLikingATrackAgainClearsItsTombstone() {
        let store = MusicLibraryStore()
        let value = track(id: 1, owner: 42, title: "Again")
        store.markRemoved(value)

        store.markAdded(source: value, stored: value)
        store.include([value])

        XCTAssertTrue(store.contains(value))
    }

    private func track(
        id: Int,
        owner: Int,
        title: String
    ) -> Track {
        Track(
            trackID: id,
            ownerID: owner,
            title: title,
            artist: "Artist",
            duration: 180,
            streamURL: nil,
            artworkURL: nil
        )
    }
}

@MainActor
final class TrackCollectionViewModelTests: XCTestCase {
    func testFailedLoadKeepsPriorTracksAndSetsError() async {
        let model = TrackCollectionViewModel(source: .library)
        let first = await model.load {
            MusicPage(
                items: [track(id: 1)],
                totalCount: 1,
                nextOffset: nil
            )
        }
        XCTAssertTrue(first)
        XCTAssertEqual(model.tracks.count, 1)

        let second = await model.load(force: true) {
            throw APIError.server(code: 1, message: "boom")
        }

        XCTAssertFalse(second)
        XCTAssertEqual(model.tracks.count, 1)
        XCTAssertEqual(model.errorMessage, "boom")
    }

    func testInsertAddedIncrementsTotalCountOnce() {
        let model = TrackCollectionViewModel(source: .library)
        let value = track(id: 7)
        model.insertAdded(value)
        model.insertAdded(value)
        XCTAssertEqual(model.tracks.count, 1)
        XCTAssertEqual(model.totalCount, 1)
    }

    func testReloadReconcilesOptimisticAdditionWithoutResortingPage() async {
        let model = TrackCollectionViewModel(source: .library)
        await model.load {
            MusicPage(
                items: [track(id: 2), track(id: 3)],
                totalCount: 2,
                nextOffset: nil
            )
        }

        model.insertAdded(track(id: 1))
        let loaded = await model.load(force: true) {
            // Server already placed track 1 in its real slot — reload must
            // keep that page order, not hoist the optimistic id to index 0.
            MusicPage(
                items: [
                    track(id: 2),
                    track(id: 1),
                    track(id: 3),
                    track(id: 4)
                ],
                totalCount: 4,
                nextOffset: nil
            )
        }

        XCTAssertTrue(loaded)
        XCTAssertEqual(
            model.tracks.map(\.id),
            ["1_2", "1_1", "1_3", "1_4"]
        )
        XCTAssertEqual(model.totalCount, 4)
    }

    func testReloadKeepsMissingOptimisticAdditionAtFront() async {
        let model = TrackCollectionViewModel(source: .library)
        await model.load {
            MusicPage(
                items: [track(id: 2), track(id: 3)],
                totalCount: 2,
                nextOffset: nil
            )
        }

        model.insertAdded(track(id: 1))
        let loaded = await model.load(force: true) {
            MusicPage(
                items: [track(id: 2), track(id: 3)],
                totalCount: 2,
                nextOffset: nil
            )
        }

        XCTAssertTrue(loaded)
        XCTAssertEqual(
            model.tracks.map(\.id),
            ["1_1", "1_2", "1_3"]
        )
        XCTAssertEqual(model.totalCount, 3)
    }

    func testLoadMorePreservesExistingAndIncomingPageOrder() async {
        let model = TrackCollectionViewModel(source: .library)
        await model.load {
            MusicPage(
                items: [track(id: 3), track(id: 1)],
                totalCount: 4,
                nextOffset: 2
            )
        }

        let loaded = await model.loadMore { offset in
            XCTAssertEqual(offset, 2)
            return MusicPage(
                items: [
                    track(id: 1),
                    track(id: 2),
                    track(id: 4)
                ],
                totalCount: 4,
                nextOffset: nil
            )
        }

        XCTAssertTrue(loaded)
        XCTAssertEqual(
            model.tracks.map(\.id),
            ["1_3", "1_1", "1_2", "1_4"]
        )
        XCTAssertEqual(model.totalCount, 4)
    }

    // Unliking a track shifts every audio.get offset below it, so the page
    // that was already in flight describes a window that no longer exists.
    // Appending it interleaved old rows into the fresh list, which is the
    // «очереди в медиатеке все равно не по очереди» report.
    func testAStalePageIsDiscardedWhenALocalEditLandsFirst() async {
        let model = TrackCollectionViewModel(source: .library)
        await model.load {
            MusicPage(
                items: [track(id: 1), track(id: 2)],
                totalCount: 4,
                nextOffset: 2
            )
        }

        let loaded = await model.loadMore { _ in
            model.removeLocally(self.track(id: 1))
            return MusicPage(
                items: [track(id: 3), track(id: 4)],
                totalCount: 4,
                nextOffset: nil
            )
        }

        XCTAssertFalse(loaded)
        XCTAssertEqual(model.tracks.map(\.id), ["1_2"])
    }

    func testAStalePageFailureDoesNotSurfaceAnError() async {
        let model = TrackCollectionViewModel(source: .library)
        await model.load {
            MusicPage(
                items: [track(id: 1)],
                totalCount: 2,
                nextOffset: 1
            )
        }

        let loaded = await model.loadMore { _ in
            model.removeLocally(self.track(id: 1))
            throw APIError.server(code: 1, message: "boom")
        }

        XCTAssertFalse(loaded)
        XCTAssertNil(model.errorMessage)
    }

    private func track(id: Int) -> Track {
        Track(
            trackID: id,
            ownerID: 1,
            title: "T",
            artist: "A",
            duration: 10,
            streamURL: nil,
            artworkURL: nil
        )
    }
}
