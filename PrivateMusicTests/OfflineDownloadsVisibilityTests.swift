import XCTest
@testable import PrivateMusic

final class PlaylistDownloadsVisibilityTests: XCTestCase {
    func testStaleFailedPlaylistWithoutLocalTracksIsHidden() {
        let record = makeRecord(state: .failed, tracks: [makeTrack()])
        XCTAssertFalse(
            PlaylistDownloadsVisibility.shouldShowDownloaded(
                record,
                hasLocalTracks: false
            )
        )
    }

    func testFailedPlaylistWithLocalTracksIsShown() {
        let record = makeRecord(state: .failed, tracks: [makeTrack()])
        XCTAssertTrue(
            PlaylistDownloadsVisibility.shouldShowDownloaded(
                record,
                hasLocalTracks: true
            )
        )
    }

    func testCancelledPlaylistWithoutLocalTracksIsHidden() {
        let record = makeRecord(state: .cancelled)
        XCTAssertFalse(
            PlaylistDownloadsVisibility.shouldShowDownloaded(
                record,
                hasLocalTracks: false
            )
        )
    }

    func testAvailablePlaylistIsAlwaysShown() {
        let record = makeRecord(state: .available)
        XCTAssertTrue(
            PlaylistDownloadsVisibility.shouldShowDownloaded(
                record,
                hasLocalTracks: false
            )
        )
    }

    func testPartialPlaylistIsAlwaysShown() {
        let record = makeRecord(
            state: .partial,
            tracks: [makeTrack()],
            completedCount: 1
        )
        XCTAssertTrue(
            PlaylistDownloadsVisibility.shouldShowDownloaded(
                record,
                hasLocalTracks: true
            )
        )
    }

    func testActiveStatesAreNeverShown() {
        for state: OfflinePlaylistDownloadState in [
            .idle, .resolvingTracks, .queued, .downloading
        ] {
            XCTAssertFalse(
                PlaylistDownloadsVisibility.shouldShowDownloaded(
                    makeRecord(state: state, tracks: [makeTrack()]),
                    hasLocalTracks: true
                ),
                "\(state) must never appear in downloaded playlists"
            )
        }
    }

    private func makeRecord(
        state: OfflinePlaylistDownloadState,
        tracks: [Track] = [],
        completedCount: Int = 0
    ) -> OfflinePlaylistRecord {
        OfflinePlaylistRecord(
            playlist: Playlist(
                id: 1,
                ownerID: -1,
                title: "Playlist",
                count: tracks.count
            ),
            tracks: tracks,
            state: state,
            completedCount: completedCount
        )
    }

    private func makeTrack() -> Track {
        Track(
            trackID: 1,
            ownerID: -1,
            title: "Title",
            artist: "Artist",
            duration: 120,
            streamURL: nil,
            artworkURL: nil
        )
    }
}

final class DownloadStorageTextTests: XCTestCase {
    func testSubtitleShowsStoredAudioAndConfiguredLimit() {
        let usage = StorageUsage(
            manualBytes: 100,
            automaticBytes: 50,
            artworkBytes: 10,
            stagingBytes: 20,
            orphanBytes: 10,
            manualCount: 2,
            automaticCount: 1,
            totalCount: 3,
            limitBytes: 5_000
        )

        let lines = DownloadStorageText.summary(usage: usage) {
            "\($0)"
        }

        XCTAssertTrue(lines.subtitle.contains("150"))
        XCTAssertTrue(lines.subtitle.contains("5000"))
        XCTAssertTrue(lines.manual.contains("100"))
        XCTAssertTrue(lines.cache.contains("50"))
        XCTAssertTrue(
            lines.overhead.contains("40"),
            "Overhead must be total minus audio, got \(lines.overhead)"
        )
    }

    func testOverheadIsNeverNegative() {
        let usage = StorageUsage(
            manualBytes: 0,
            automaticBytes: 0,
            artworkBytes: 0,
            stagingBytes: 0,
            orphanBytes: 0,
            manualCount: 0,
            automaticCount: 0,
            totalCount: 0,
            limitBytes: 5_000
        )

        let lines = DownloadStorageText.summary(usage: usage) {
            "\($0)"
        }

        XCTAssertTrue(lines.overhead.contains("0"))
    }
}
