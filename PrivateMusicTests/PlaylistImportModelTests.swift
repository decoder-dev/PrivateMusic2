import XCTest
@testable import PrivateMusic

@MainActor
final class PlaylistImportModelTests: XCTestCase {
    private func model() -> PlaylistImportModel {
        let model = PlaylistImportModel()
        model.rows = (1...3).map { id in
            let track = Track(trackID: id, ownerID: 1, title: "Song \(id)", artist: "Band",
                              duration: 200, streamURL: nil, artworkURL: nil)
            return .init(item: .init(artist: track.artist, title: track.title),
                         match: .init(track: track, confidence: 1), include: true)
        }
        return model
    }

    func testStoppingAfterAcceptedWriteReportsPartialPlaylistAndCannotCreateDuplicate() async {
        let model = model()
        var creates = 0
        var adds = 0
        let make: () async throws -> Playlist = {
            creates += 1
            return Playlist(id: 10, ownerID: 1, title: "Import", count: 0)
        }
        await model.create(makePlaylist: make, addTrack: { _, _ in
            adds += 1
            model.requestStop()
        }, spacing: .zero)
        XCTAssertEqual(model.stage, .done(added: 1, failed: 0))
        XCTAssertEqual(model.remainingCount, 2)
        XCTAssertTrue(model.wasStopped)
        await model.create(makePlaylist: make, addTrack: { _, _ in adds += 1 }, spacing: .zero)
        XCTAssertEqual(creates, 1)
        XCTAssertEqual(adds, 1)
    }

    func testStoppingDuringCreationWaitsForPlaylistResponseAndAddsNoTracks() async {
        let model = model()
        var adds = 0
        await model.create(makePlaylist: {
            model.requestStop()
            return Playlist(id: 10, ownerID: 1, title: "Import", count: 0)
        }, addTrack: { _, _ in adds += 1 }, spacing: .zero)
        XCTAssertEqual(model.stage, .done(added: 0, failed: 0))
        XCTAssertEqual(model.remainingCount, 3)
        XCTAssertTrue(model.wasStopped)
        XCTAssertEqual(adds, 0)
    }

    func testCompletedImportKeepsFailureCountSeparateFromUnprocessedTracks() async {
        let model = model()
        await model.create(makePlaylist: {
            Playlist(id: 10, ownerID: 1, title: "Import", count: 0)
        }, addTrack: { track, _ in
            if track.trackID == 2 { throw APIError.timedOut }
        }, spacing: .zero)
        XCTAssertEqual(model.stage, .done(added: 2, failed: 1))
        XCTAssertEqual(model.remainingCount, 0)
        XCTAssertFalse(model.wasStopped)
    }
}
