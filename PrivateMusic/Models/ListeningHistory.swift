import Foundation

struct ListeningHistoryEntry: Codable, Hashable, Identifiable, Sendable {
    let track: Track
    let playedAt: Date

    var id: String { "\(track.id)-\(playedAt.timeIntervalSince1970)" }
}

@MainActor
final class ListeningHistoryStore: ObservableObject {
    @Published private(set) var entries: [ListeningHistoryEntry]

    private let defaults: UserDefaults
    private let key = "listening.history.v1"
    private let limit = 250

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = (defaults.data(forKey: key))
            .flatMap { try? JSONDecoder().decode(
                [ListeningHistoryEntry].self,
                from: $0
            ) } ?? []
    }

    func record(_ track: Track) {
        entries.removeAll { $0.track.id == track.id }
        entries.insert(
            ListeningHistoryEntry(track: track, playedAt: Date()),
            at: 0
        )
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
        persist()
    }

    func remove(_ entry: ListeningHistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    func clear() {
        entries = []
        defaults.removeObject(forKey: key)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}
