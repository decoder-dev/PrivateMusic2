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
    }

    func testRemovalClearsSignature() {
        let store = MusicLibraryStore()
        let value = track(id: 1, owner: 42, title: "Track")
        store.replace(with: [value])

        store.markRemoved(value)

        XCTAssertFalse(store.contains(value))
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
