import XCTest
@testable import PrivateMusic

@MainActor
final class LocalAudioLibraryTests: XCTestCase {
    func testImportCopiesPlayableAudioPersistsAndDeduplicates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("Original.wav")
        let bytes = wav()
        try bytes.write(to: original)
        let directory = root.appendingPathComponent("Library")
        let library = LocalAudioLibrary(directory: directory)
        await library.importFiles([original, original])
        XCTAssertNil(library.errorMessage)
        XCTAssertEqual(library.entries.count, 1)
        let track = try XCTUnwrap(library.tracks.first)
        XCTAssertTrue(track.isLocal)
        XCTAssertEqual(track.title, "Original")
        XCTAssertNil(track.streamURL)
        XCTAssertEqual(track.trackID, 0)
        XCTAssertEqual(track.ownerID, 0)
        let copied = try XCTUnwrap(library.localURL(for: track))
        XCTAssertNotEqual(copied, original)
        XCTAssertEqual(try Data(contentsOf: copied), bytes)
        let restored = LocalAudioLibrary(directory: directory)
        XCTAssertEqual(restored.tracks.map(\.id), [track.id])
        XCTAssertNotNil(restored.localURL(for: track))
        try await restored.remove(try XCTUnwrap(restored.entries.first))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.path))
        XCTAssertTrue(LocalAudioLibrary(directory: directory).entries.isEmpty)
    }

    func testInvalidAudioDoesNotLeaveImportedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("Broken.mp3")
        try Data("this is not an audio file".utf8).write(to: original)
        let directory = root.appendingPathComponent("Library")
        let library = LocalAudioLibrary(directory: directory)
        await library.importFiles([original])
        XCTAssertNotNil(library.errorMessage)
        XCTAssertTrue(library.entries.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testLocalTrackIdentityRoundTripsWithoutRemoteURL() throws {
        let id = UUID()
        let track = Track(trackID: 0, ownerID: 0, title: "Title", artist: "Artist",
                          duration: 30, streamURL: nil, artworkURL: nil, localFileID: id)
        let decoded = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(track))
        XCTAssertEqual(decoded.id, "local:" + id.uuidString.lowercased())
        XCTAssertTrue(decoded.isLocal)
        XCTAssertNil(decoded.streamURL)
        XCTAssertEqual(decoded.resolvingStreamURL(userID: 123).localFileID, id)
        let remote = Track(trackID: 1, ownerID: 1, title: "Title", artist: "Artist", duration: 30,
                           streamURL: nil, artworkURL: nil)
        XCTAssertFalse(remote.isLocal)
        XCTAssertEqual(remote.id, "1_1")
    }

    func testIndexCannotEscapeTheLibraryOrFollowSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        let invalid = LocalAudioEntry(id: id, filename: "../private.wav", title: "Title", artist: "Artist",
                                      album: nil, duration: 20, digest: "x", hasArtwork: false, importedAt: Date())
        try JSONEncoder().encode([invalid]).write(to: root.appendingPathComponent("index.json"))
        XCTAssertTrue(LocalAudioLibrary(directory: root).entries.isEmpty)
        let valid = LocalAudioEntry(id: id, filename: id.uuidString + ".wav", title: "Title", artist: "Artist",
                                    album: nil, duration: 20, digest: "x", hasArtwork: false, importedAt: Date())
        let target = root.appendingPathComponent("outside.wav")
        try wav().write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(valid.filename), withDestinationURL: target)
        try JSONEncoder().encode([valid]).write(to: root.appendingPathComponent("index.json"))
        XCTAssertNil(LocalAudioLibrary(directory: root).localURL(for: valid.track(in: root)))
    }

    func testLocalAudioCannotBeSentToVKMutationsOrStreamRefresh() async throws {
        let service = VKMusicService(client: APIClient(baseURL: URL(string: "https://example.invalid")!), apiVersion: "5.131")
        let track = Track(trackID: 0, ownerID: 0, title: "Local", artist: "Artist", duration: 30,
                          streamURL: nil, artworkURL: nil, localFileID: UUID())
        do { _ = try await service.refreshedTrack(track, accessToken: "test"); XCTFail("Local files must not refresh through VK")
        } catch { XCTAssertEqual(error as? APIError, .invalidRequest) }
        do { _ = try await service.addToLibrary(track, accessToken: "test"); XCTFail("Local files must not be uploaded as VK IDs")
        } catch { XCTAssertEqual(error as? APIError, .invalidRequest) }
        do { try await service.broadcast(track: track, accessToken: "test"); XCTFail("Local listening must stay local")
        } catch { XCTAssertEqual(error as? APIError, .invalidRequest) }
    }

    private func wav() -> Data {
        let samples: UInt32 = 8_000
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        append(36 + samples * 2)
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(8_000)); append(UInt32(16_000)); append(UInt16(2)); append(UInt16(16))
        data.append(Data("data".utf8)); append(samples * 2)
        data.append(Data(repeating: 0, count: Int(samples * 2)))
        return data
    }
}

final class PlayerArtworkGesturePolicyTests: XCTestCase {
    func testFastFlickUsesPredictionWithoutTreatingTapsAsSwipes() {
        XCTAssertEqual(PlayerArtworkGesturePolicy.action(translation: CGSize(width: -30, height: 4),
            predictedEndTranslation: CGSize(width: -130, height: 10)), .next)
        XCTAssertEqual(PlayerArtworkGesturePolicy.action(translation: CGSize(width: 30, height: 4),
            predictedEndTranslation: CGSize(width: 130, height: 10)), .previous)
        XCTAssertNil(PlayerArtworkGesturePolicy.action(translation: CGSize(width: 8, height: 1),
            predictedEndTranslation: CGSize(width: 130, height: 10)))
    }

    func testDiagonalAndReversedFlicksDoNotChangeTracks() {
        XCTAssertNil(PlayerArtworkGesturePolicy.action(translation: CGSize(width: 60, height: 57),
            predictedEndTranslation: CGSize(width: 120, height: 110)))
        XCTAssertNil(PlayerArtworkGesturePolicy.action(translation: CGSize(width: 30, height: 0),
            predictedEndTranslation: CGSize(width: -130, height: 0)))
    }

    func testVerticalGesturesKeepQueueAndDismissActions() {
        XCTAssertEqual(PlayerArtworkGesturePolicy.action(translation: CGSize(width: 4, height: -85),
            predictedEndTranslation: CGSize(width: 8, height: -140)), .queue)
        XCTAssertEqual(PlayerArtworkGesturePolicy.action(translation: CGSize(width: 4, height: 150),
            predictedEndTranslation: CGSize(width: 8, height: 180)), .dismiss)
    }

    func testTrackInfoOmitsMissingFieldsAndTrimsWhitespace() {
        let track = Track(trackID: 1, ownerID: 1, title: "  Title\n", artist: " Artist ", duration: 30,
                          streamURL: nil, artworkURL: nil)
        XCTAssertEqual(TrackInformationText.formatted(track), "Artist — Title")
        let noArtist = Track(trackID: 1, ownerID: 1, title: "Title", artist: " \n", duration: 30,
                             streamURL: nil, artworkURL: nil)
        XCTAssertEqual(TrackInformationText.formatted(noArtist), "Title")
    }
}
