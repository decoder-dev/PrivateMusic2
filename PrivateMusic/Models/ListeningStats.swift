import Foundation

/// Compact, on-device listening statistics. The play history keeps only the
/// last 250 distinct tracks and no durations, so it cannot answer "what did I
/// listen to most this year"; this aggregate can. It stores counters per
/// month (never a play-by-play log) and never leaves the device.
struct ListeningStatsData: Codable, Equatable, Sendable {
    struct TrackTally: Codable, Equatable, Sendable {
        var title: String
        var artist: String
        var artworkURL: URL?
        var plays: Int
        var seconds: Double
    }

    struct ArtistTally: Codable, Equatable, Sendable {
        var name: String
        var plays: Int
        var seconds: Double
    }

    struct Month: Codable, Equatable, Sendable {
        var seconds: Double = 0
        var plays: Int = 0
        /// Seconds heard in each hour of the day, 0...23.
        var hourSeconds: [Double] = Array(repeating: 0, count: 24)
        /// Seconds heard on each weekday, index 0 = `Calendar` weekday 1.
        var weekdaySeconds: [Double] = Array(repeating: 0, count: 7)
        /// Seconds per day of the month, keyed "01"..."31".
        var daySeconds: [String: Double] = [:]
        var tracks: [String: TrackTally] = [:]
        var artists: [String: ArtistTally] = [:]
    }

    static let currentVersion = 1
    /// Keeps a month small however long it is used: the tail of tracks heard
    /// once cannot reach a top list anyway.
    static let trackLimit = 400
    static let trackKeepCount = 300

    var version = ListeningStatsData.currentVersion
    var months: [String: Month] = [:]

    var isEmpty: Bool {
        months.values.allSatisfy { $0.seconds <= 0 && $0.plays == 0 }
    }

    // MARK: Recording

    /// What the stats need to know about a track. Kept separate from `Track`
    /// so the aggregate has no dependency on the playback models.
    struct Subject: Equatable, Sendable {
        let id: String
        let title: String
        let artist: String
        let artistKey: String
        let artworkURL: URL?
    }

    mutating func addPlay(
        _ subject: Subject,
        at date: Date,
        calendar: Calendar
    ) {
        let key = Self.monthKey(for: date, calendar: calendar)
        var month = months[key] ?? Month()
        month.plays += 1
        var tally = month.tracks[subject.id] ?? TrackTally(
            title: subject.title,
            artist: subject.artist,
            artworkURL: subject.artworkURL,
            plays: 0,
            seconds: 0
        )
        tally.plays += 1
        month.tracks[subject.id] = tally
        if !subject.artistKey.isEmpty {
            var artist = month.artists[subject.artistKey] ?? ArtistTally(
                name: subject.artist,
                plays: 0,
                seconds: 0
            )
            artist.plays += 1
            month.artists[subject.artistKey] = artist
        }
        Self.prune(&month)
        months[key] = month
    }

    mutating func addListening(
        seconds: Double,
        subject: Subject,
        at date: Date,
        calendar: Calendar
    ) {
        guard seconds.isFinite, seconds > 0 else { return }
        let key = Self.monthKey(for: date, calendar: calendar)
        var month = months[key] ?? Month()
        month.seconds += seconds
        let parts = calendar.dateComponents([.hour, .weekday, .day], from: date)
        if let hour = parts.hour, (0..<24).contains(hour) {
            month.hourSeconds[hour] += seconds
        }
        if let weekday = parts.weekday, (1...7).contains(weekday) {
            month.weekdaySeconds[weekday - 1] += seconds
        }
        if let day = parts.day {
            let dayKey = String(format: "%02d", day)
            month.daySeconds[dayKey, default: 0] += seconds
        }
        // The "listened" event that counts a play fires only after some
        // seconds, so the tallies may not exist yet: create them here and let
        // `addPlay` raise the play count later.
        var tally = month.tracks[subject.id] ?? TrackTally(
            title: subject.title,
            artist: subject.artist,
            artworkURL: subject.artworkURL,
            plays: 0,
            seconds: 0
        )
        tally.seconds += seconds
        month.tracks[subject.id] = tally
        if !subject.artistKey.isEmpty {
            var artist = month.artists[subject.artistKey] ?? ArtistTally(
                name: subject.artist,
                plays: 0,
                seconds: 0
            )
            artist.seconds += seconds
            month.artists[subject.artistKey] = artist
        }
        Self.prune(&month)
        months[key] = month
    }

    static func monthKey(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 1970, parts.month ?? 1)
    }

    private static func prune(_ month: inout Month) {
        guard month.tracks.count > trackLimit else { return }
        let keep = month.tracks
            .sorted { lhs, rhs in
                if lhs.value.plays != rhs.value.plays {
                    return lhs.value.plays > rhs.value.plays
                }
                if lhs.value.seconds != rhs.value.seconds {
                    return lhs.value.seconds > rhs.value.seconds
                }
                return lhs.key < rhs.key
            }
            .prefix(trackKeepCount)
        month.tracks = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }
}

/// The numbers a stats screen shows for one period.
struct ListeningSummary: Equatable, Sendable {
    enum Period: Equatable, Hashable, Sendable {
        case month(String)
        case year(Int)
        case allTime
    }

    struct Entry: Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        let subtitle: String?
        let artworkURL: URL?
        let plays: Int
        let seconds: Double
    }

    struct Day: Equatable, Sendable {
        /// "yyyy-MM-dd"
        let key: String
        let seconds: Double
    }

    static let topCount = 5
    /// A day counts as "with music" from one minute of listening.
    static let activeDayThreshold: Double = 60

    let period: Period
    let totalSeconds: Double
    let plays: Int
    let activeDays: Int
    let topArtists: [Entry]
    let topTracks: [Entry]
    let hourSeconds: [Double]
    /// Hour of day with the most listening, nil without data.
    let peakHour: Int?
    /// `Calendar` weekday (1...7) with the most listening, nil without data.
    let favouriteWeekday: Int?
    let busiestDay: Day?

    var isEmpty: Bool { totalSeconds <= 0 && plays == 0 }

    static func make(
        from data: ListeningStatsData,
        period: Period
    ) -> ListeningSummary {
        let selected = data.months
            .filter { matches($0.key, period) }
            .sorted { $0.key < $1.key }

        var totalSeconds = 0.0
        var plays = 0
        var hours = [Double](repeating: 0, count: 24)
        var weekdays = [Double](repeating: 0, count: 7)
        var days: [String: Double] = [:]
        var tracks: [String: ListeningStatsData.TrackTally] = [:]
        var artists: [String: ListeningStatsData.ArtistTally] = [:]

        for (monthKey, month) in selected {
            totalSeconds += month.seconds
            plays += month.plays
            for index in 0..<24 where index < month.hourSeconds.count {
                hours[index] += month.hourSeconds[index]
            }
            for index in 0..<7 where index < month.weekdaySeconds.count {
                weekdays[index] += month.weekdaySeconds[index]
            }
            for (day, seconds) in month.daySeconds {
                days["\(monthKey)-\(day)"] = seconds
            }
            for (id, tally) in month.tracks {
                if var merged = tracks[id] {
                    merged.plays += tally.plays
                    merged.seconds += tally.seconds
                    // Newest month wins for display fields.
                    merged.title = tally.title
                    merged.artist = tally.artist
                    merged.artworkURL = tally.artworkURL ?? merged.artworkURL
                    tracks[id] = merged
                } else {
                    tracks[id] = tally
                }
            }
            for (key, tally) in month.artists {
                if var merged = artists[key] {
                    merged.plays += tally.plays
                    merged.seconds += tally.seconds
                    merged.name = tally.name
                    artists[key] = merged
                } else {
                    artists[key] = tally
                }
            }
        }

        let topTracks = tracks
            .map { id, tally in
                Entry(
                    id: id,
                    title: tally.title,
                    subtitle: tally.artist.isEmpty ? nil : tally.artist,
                    artworkURL: tally.artworkURL,
                    plays: tally.plays,
                    seconds: tally.seconds
                )
            }
            .sorted(by: ranking)
            .prefix(topCount)

        let topArtists = artists
            .map { key, tally in
                Entry(
                    id: key,
                    title: tally.name,
                    subtitle: nil,
                    artworkURL: nil,
                    plays: tally.plays,
                    seconds: tally.seconds
                )
            }
            .sorted(by: ranking)
            .prefix(topCount)

        let busiest = days
            .max { lhs, rhs in
                lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
            }
            .flatMap { $0.value > 0 ? Day(key: $0.key, seconds: $0.value) : nil }

        return ListeningSummary(
            period: period,
            totalSeconds: totalSeconds,
            plays: plays,
            activeDays: days.values.filter { $0 >= activeDayThreshold }.count,
            topArtists: Array(topArtists),
            topTracks: Array(topTracks),
            hourSeconds: hours,
            peakHour: peakIndex(hours),
            favouriteWeekday: peakIndex(weekdays).map { $0 + 1 },
            busiestDay: busiest
        )
    }

    /// Periods that have any data, newest first.
    static func availableMonths(in data: ListeningStatsData) -> [String] {
        data.months
            .filter { $0.value.seconds > 0 || $0.value.plays > 0 }
            .map(\.key)
            .sorted(by: >)
    }

    static func availableYears(in data: ListeningStatsData) -> [Int] {
        Array(Set(availableMonths(in: data).compactMap { Int($0.prefix(4)) }))
            .sorted(by: >)
    }

    private static func matches(_ monthKey: String, _ period: Period) -> Bool {
        switch period {
        case .allTime: return true
        case .month(let key): return monthKey == key
        case .year(let year): return monthKey.hasPrefix(String(format: "%04d-", year))
        }
    }

    private static func ranking(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.plays != rhs.plays { return lhs.plays > rhs.plays }
        if lhs.seconds != rhs.seconds { return lhs.seconds > rhs.seconds }
        return lhs.id < rhs.id
    }

    /// Index of the largest value; the earliest wins a tie. Nil when all zero.
    private static func peakIndex(_ values: [Double]) -> Int? {
        var best: Int?
        for (index, value) in values.enumerated() where value > 0 {
            if best == nil || value > values[best!] { best = index }
        }
        return best
    }
}
