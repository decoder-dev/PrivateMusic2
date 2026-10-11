import XCTest
@testable import PrivateMusic

final class AudioShareMetadataTests: XCTestCase {
    private let track = Track(trackID: 7, ownerID: 2, title: "Вечер", artist: "Музыкант", duration: 200,
                              streamURL: nil, artworkURL: nil)

    func testMP3TaggingPreservesAudioAndDoesNotModifyHardLinkedOfflineSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.mp3")
        let exported = directory.appendingPathComponent("export.mp3")
        let audio = Data([0xff, 0xfb, 0x90, 0x00] + Array(repeating: 42, count: 1200))
        try audio.write(to: original)
        try FileManager.default.linkItem(at: original, to: exported)
        try ID3MetadataWriter.write(url: exported, track: track, artwork: nil)
        try ID3MetadataWriter.write(url: exported, track: track, artwork: nil)
        let result = try Data(contentsOf: exported)
        let tagLength = try ID3MetadataWriter.decodeSize(result[6..<10], synchsafe: true)
        XCTAssertEqual(Data(result.dropFirst(tagLength + 10)), audio)
        XCTAssertEqual(try Data(contentsOf: original), audio)
        XCTAssertTrue(result.range(of: Data("Вечер".utf8)) != nil)
        XCTAssertTrue(result.range(of: Data("Музыкант".utf8)) != nil)
    }

    func testUnsupportedTagRemainsUntouched() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data("ID3".utf8) + Data([2, 0, 0, 0, 0, 0, 0, 0xff, 0xfb])
        try bytes.write(to: url)
        XCTAssertThrowsError(try ID3MetadataWriter.write(url: url, track: track, artwork: nil))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testSyncedTextExportsAsLRCWithFiniteTimestamps() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("audio.aac")
        try Data([1, 2, 3]).write(to: url)
        try await AudioShareEnricher().enrich(url, track: track, artwork: nil,
             lyrics: Lyrics(text: "Hello", source: "LRCLIB", lines: [
                LyricLine(time: 61.25, text: "Hello"), LyricLine(time: .infinity, text: "Invalid")
             ]))
        let lrc = url.deletingPathExtension().appendingPathExtension("lrc")
        XCTAssertEqual(try String(contentsOf: lrc, encoding: .utf8), "[01:01.25]Hello")
        XCTAssertEqual(TrackSharePayload.audioFile(url).files, [url, lrc])
    }

    func testWidgetLinksContainOnlyAccountAndTrackIdentity() throws {
        let track = RecentWidgetTrack(id: "2_7", title: "Вечер", artist: "Музыкант", artwork: nil)
        let snapshot = RecentWidgetSnapshot(accountID: 42, tracks: [track])
        let url = try XCTUnwrap(snapshot.url(for: track))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(Set(items.map(\.name)), ["account", "track"])
        XCTAssertEqual(items.first { $0.name == "account" }?.value, "42")
        XCTAssertNil(RecentWidgetSnapshot(accountID: nil, tracks: []).url(for: track))
    }
}
