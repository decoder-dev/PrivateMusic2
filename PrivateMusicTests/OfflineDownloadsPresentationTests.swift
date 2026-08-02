import XCTest
@testable import PrivateMusic

final class OfflineDownloadsPresentationTests: XCTestCase {
    func testPlaylistWorkerTracksAreNotCountedTwice() {
        let count = OfflineDownloadsPresentation.activeDownloadCount(
            downloadingTrackIDs: ["playlist-1", "playlist-2", "manual"],
            activePlaylistTrackIDs: ["playlist-1", "playlist-2"],
            activePlaylistCount: 1
        )

        XCTAssertEqual(count, 2)
    }

    func testStandaloneDownloadsRemainIndividuallyCounted() {
        let count = OfflineDownloadsPresentation.activeDownloadCount(
            downloadingTrackIDs: ["one", "two"],
            activePlaylistTrackIDs: [],
            activePlaylistCount: 0
        )

        XCTAssertEqual(count, 2)
    }
}
