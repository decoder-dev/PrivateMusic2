import XCTest
@testable import PrivateMusic

@MainActor
final class ListeningHistoryStoreTests: XCTestCase {
    func testConsecutiveSameTrackRecordIsIgnored() {
        let suite = "ListeningHistoryStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ListeningHistoryStore(defaults: defaults)
        let first = track(id: 1)

        store.record(first)
        let playedAt = store.entries.first?.playedAt
        store.record(first)

        XCTAssertEqual(store.entries.map(\.track.id), [first.id])
        XCTAssertEqual(store.entries.first?.playedAt, playedAt)
    }

    func testRecordTrimsHistoryToMaximumEntries() {
        let suite = "ListeningHistoryStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ListeningHistoryStore(defaults: defaults)

        for id in 1...(ListeningHistoryStore.maximumEntries + 5) {
            store.record(track(id: id))
        }

        XCTAssertEqual(store.entries.count, ListeningHistoryStore.maximumEntries)
        XCTAssertEqual(store.entries.first?.track.id, track(id: 255).id)
        XCTAssertEqual(store.entries.last?.track.id, track(id: 6).id)
    }

    private func track(id: Int) -> Track {
        Track(
            trackID: id,
            ownerID: 10,
            title: "Track \(id)",
            artist: "Artist",
            duration: 180,
            streamURL: URL(string: "https://example.com/\(id).mp3"),
            artworkURL: nil
        )
    }
}
