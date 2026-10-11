import XCTest
@testable import PrivateMusic

@MainActor
final class SavedLyricsStoreTests: XCTestCase {
    private let track = Track(trackID: 7, ownerID: 2, title: "Вечер", artist: "Музыкант", duration: 200,
                              streamURL: URL(string: "https://example.com/signed-secret"), artworkURL: nil,
                              accessKey: "private-key")

    func testSavedLyricsStayWithTheirAccountAndExcludeCredentials() throws {
        let suite = "SavedLyricsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SavedLyricsStore(defaults: defaults)
        store.configure(accountID: 1)
        store.save(Lyrics(text: "Свет в окне", source: "LRCLIB"), for: track)
        let persisted = String(decoding: try XCTUnwrap(defaults.data(forKey: "lyrics.saved.v1.1")), as: UTF8.self)
        XCTAssertFalse(persisted.contains("signed-secret"))
        XCTAssertFalse(persisted.contains("private-key"))
        store.configure(accountID: 2)
        XCTAssertTrue(store.records.isEmpty)
        store.configure(accountID: 1)
        XCTAssertEqual(store.lyrics(for: track)?.text, "Свет в окне")
        store.configure(accountID: nil)
        XCTAssertTrue(store.records.isEmpty)
    }

    func testSearchMatchesEveryWordWithoutCaseOrAccentSensitivity() {
        let suite = "SavedLyricsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SavedLyricsStore(defaults: defaults)
        store.configure(accountID: 1)
        store.save(Lyrics(text: "ТЁПЛЫЙ свет в окне", source: "LRCLIB"), for: track)
        XCTAssertEqual(store.search("теплый ОКНЕ").count, 1)
        XCTAssertTrue(store.search("свет море").isEmpty)
        XCTAssertTrue(store.search(" ").isEmpty)
    }

    func testRepeatedSaveUpdatesOneRecordAndAnonymousSaveIsIgnored() {
        let suite = "SavedLyricsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SavedLyricsStore(defaults: defaults)
        store.save(Lyrics(text: "Old", source: "LRCLIB"), for: track)
        XCTAssertTrue(store.records.isEmpty)
        store.configure(accountID: 1)
        store.save(Lyrics(text: "Old", source: "LRCLIB"), for: track)
        store.save(Lyrics(text: "New", source: "Genius"), for: track)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.lyrics(for: track)?.text, "New")
    }
}
