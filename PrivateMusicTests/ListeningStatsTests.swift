import XCTest
@testable import PrivateMusic

final class ListeningStatsTests: XCTestCase {
    @MainActor
    func testFailedSaveRetriesWithoutNewListeningAndPreservesPreviousAccount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("blocked-stats-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        // A regular file where a directory is needed makes the write fail.
        try Data([1]).write(to: directory)
        let store = ListeningStatsStore(directory: directory)
        let track = Track(trackID: 1, ownerID: 1, title: "Song", artist: "Band",
                          duration: 200, streamURL: nil, artworkURL: nil)
        store.configure(accountID: 7)
        store.recordListening(seconds: 12, track: track)
        store.saveNow()
        store.configure(accountID: 8)
        store.recordListening(seconds: 15, track: track)
        store.saveNow()

        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store.saveNow() // No new listening event: both failed writes must retry.
        let restored = ListeningStatsStore(directory: directory)
        restored.configure(accountID: 7)
        XCTAssertEqual(ListeningSummary.make(from: restored.data, period: .allTime).totalSeconds, 12)
        restored.configure(accountID: 8)
        XCTAssertEqual(ListeningSummary.make(from: restored.data, period: .allTime).totalSeconds, 15)
    }

    @MainActor
    func testClearingStatisticsDiscardsAFailedPendingWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cleared-stats-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1]).write(to: directory)
        let store = ListeningStatsStore(directory: directory)
        store.configure(accountID: 7)
        store.recordPlay(Track(trackID: 1, ownerID: 1, title: "Song", artist: "Band",
                               duration: 200, streamURL: nil, artworkURL: nil))
        store.saveNow()
        store.clear()
        try FileManager.default.removeItem(at: directory)
        store.saveNow()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("listening-7.json").path))
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso) ?? Date(timeIntervalSince1970: 0)
    }

    private func subject(_ id: String, _ artist: String) -> ListeningStatsData.Subject {
        .init(
            id: id,
            title: "Track \(id)",
            artist: artist,
            artistKey: artist.lowercased(),
            artworkURL: nil
        )
    }

    private func sampleData() -> ListeningStatsData {
        var data = ListeningStatsData()
        data.addListening(seconds: 200, subject: subject("a1", "X"), at: date("2026-10-05T21:30:00Z"), calendar: calendar)
        data.addPlay(subject("a1", "X"), at: date("2026-10-05T21:33:00Z"), calendar: calendar)
        data.addListening(seconds: 100, subject: subject("b2", "Y"), at: date("2026-10-06T08:10:00Z"), calendar: calendar)
        data.addPlay(subject("b2", "Y"), at: date("2026-10-06T08:11:00Z"), calendar: calendar)
        data.addPlay(subject("b2", "Y"), at: date("2026-10-06T08:20:00Z"), calendar: calendar)
        data.addListening(seconds: 50, subject: subject("c3", "X"), at: date("2026-11-02T10:00:00Z"), calendar: calendar)
        data.addPlay(subject("c3", "X"), at: date("2026-11-02T10:01:00Z"), calendar: calendar)
        return data
    }

    func testMonthSummaryRanksByPlaysAndFindsHabits() {
        let summary = ListeningSummary.make(from: sampleData(), period: .month("2026-10"))
        XCTAssertEqual(summary.totalSeconds, 300)
        XCTAssertEqual(summary.plays, 3)
        XCTAssertEqual(summary.topTracks.first?.id, "b2")
        XCTAssertEqual(summary.topArtists.map(\.id), ["y", "x"])
        XCTAssertEqual(summary.peakHour, 21)
        XCTAssertEqual(summary.favouriteWeekday, 2)
        XCTAssertEqual(summary.busiestDay?.key, "2026-10-05")
        XCTAssertEqual(summary.activeDays, 2)
    }

    func testYearAndAllTimeMergeMonths() {
        let data = sampleData()
        let year = ListeningSummary.make(from: data, period: .year(2026))
        XCTAssertEqual(year.totalSeconds, 350)
        XCTAssertEqual(year.plays, 4)
        XCTAssertEqual(year.topArtists.first?.id, "x")
        XCTAssertEqual(ListeningSummary.make(from: data, period: .allTime), ListeningSummary.make(from: data, period: .year(2026)).withPeriod(.allTime))
        XCTAssertEqual(ListeningSummary.availableMonths(in: data), ["2026-11", "2026-10"])
        XCTAssertEqual(ListeningSummary.availableYears(in: data), [2026])
    }

    func testEmptyPeriodAndInvalidInputAreHarmless() {
        var data = ListeningStatsData()
        data.addListening(seconds: .nan, subject: subject("z", "Z"), at: Date(), calendar: calendar)
        data.addListening(seconds: -1, subject: subject("z", "Z"), at: Date(), calendar: calendar)
        XCTAssertTrue(data.isEmpty)
        let summary = ListeningSummary.make(from: sampleData(), period: .month("2025-01"))
        XCTAssertTrue(summary.isEmpty)
        XCTAssertNil(summary.peakHour)
        XCTAssertNil(summary.busiestDay)
    }

    func testMonthIsPrunedButPlayTotalStaysExact() {
        var data = ListeningStatsData()
        var expectedPlays = 0
        for index in 0..<450 {
            for _ in 0...(index % 7) {
                data.addPlay(subject("t\(index)", "A\(index % 5)"), at: date("2026-10-05T10:00:00Z"), calendar: calendar)
                expectedPlays += 1
            }
        }
        let month = data.months["2026-10"]
        XCTAssertLessThanOrEqual(month?.tracks.count ?? 0, ListeningStatsData.trackLimit)
        XCTAssertEqual(month?.plays, expectedPlays)
    }

    func testCodableRoundTrip() throws {
        let data = sampleData()
        let decoded = try JSONDecoder().decode(
            ListeningStatsData.self,
            from: JSONEncoder().encode(data)
        )
        XCTAssertEqual(decoded, data)
    }

    @MainActor
    func testStoreCollectsSecondsPersistsAndSeparatesAccounts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = date("2026-10-05T21:30:00Z")
        let calendar = self.calendar
        let store = ListeningStatsStore(directory: directory, calendar: { calendar }, now: { now })
        let track = Track(
            trackID: 1, ownerID: 1, title: "Song", artist: "Band",
            duration: 200, streamURL: nil, artworkURL: nil
        )

        store.recordListening(seconds: 5, track: track)
        XCTAssertTrue(store.data.isEmpty, "nothing is recorded before an account is set")

        store.configure(accountID: 7)
        for _ in 0..<40 { store.recordListening(seconds: 0.5, track: track) }
        store.recordPlay(track)
        now += 3_600
        store.saveNow()

        let summary = ListeningSummary.make(from: store.data, period: .allTime)
        XCTAssertEqual(summary.totalSeconds, 20)
        XCTAssertEqual(summary.plays, 1)
        XCTAssertEqual(summary.peakHour, 21)

        let reopened = ListeningStatsStore(directory: directory, calendar: { calendar }, now: { now })
        reopened.configure(accountID: 7)
        XCTAssertEqual(reopened.data, store.data)
        reopened.configure(accountID: 8)
        XCTAssertTrue(reopened.data.isEmpty)

        reopened.configure(accountID: 7)
        reopened.clear()
        let cleared = ListeningStatsStore(directory: directory, calendar: { calendar }, now: { now })
        cleared.configure(accountID: 7)
        XCTAssertTrue(cleared.data.isEmpty)
    }
}

private extension ListeningSummary {
    /// Same numbers under another period label, for comparing year vs all-time.
    func withPeriod(_ period: Period) -> ListeningSummary {
        ListeningSummary(
            period: period, totalSeconds: totalSeconds, plays: plays,
            activeDays: activeDays, topArtists: topArtists, topTracks: topTracks,
            hourSeconds: hourSeconds, peakHour: peakHour,
            favouriteWeekday: favouriteWeekday, busiestDay: busiestDay
        )
    }
}
