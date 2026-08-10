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
            ["1_1", "1_2", "1_3", "1_4"]
        )
        XCTAssertEqual(model.totalCount, 4)
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
