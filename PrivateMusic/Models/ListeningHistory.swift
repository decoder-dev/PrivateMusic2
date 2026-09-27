import Foundation

struct ListeningHistoryEntry: Codable, Hashable, Identifiable, Sendable {
    let track: Track
    let playedAt: Date

    var id: String { "\(track.id)-\(playedAt.timeIntervalSince1970)" }
}

@MainActor
@Observable
final class ListeningHistoryStore {
    static let maximumEntries = 250

    private(set) var entries: [ListeningHistoryEntry] = []

    private let defaults: UserDefaults
    private var accountID: Int?
    private var key: String? {
        accountID.map { "listening.history.v2.\($0)" }
    }
    private static let saveDebounceNanoseconds: UInt64 = 350_000_000
    private var saveTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, accountID: Int? = nil) {
        self.defaults = defaults
        configure(accountID: accountID)
    }

    func configure(accountID: Int?) {
        guard self.accountID != accountID else { return }
        saveTask?.cancel()
        saveTask = nil
        // Flush the outgoing account before changing its storage key.
        if let key, let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
        self.accountID = accountID
        entries = []
        // The legacy global history has no reliable owner. Keep it on disk
        // rather than assigning another user's listening data to this account.
        guard let key else { return }
        let storedEntries = (defaults.data(forKey: key))
            .flatMap { try? JSONDecoder().decode(
                [ListeningHistoryEntry].self,
                from: $0
            ) } ?? []
        entries = Array(storedEntries.prefix(Self.maximumEntries))
        if storedEntries.count > Self.maximumEntries {
            schedulePersist()
        }
    }

    func record(_ track: Track) {
        if entries.first?.track.id == track.id {
            return
        }
        entries.removeAll { $0.track.id == track.id }
        entries.insert(
            ListeningHistoryEntry(track: track, playedAt: Date()),
            at: 0
        )
        if entries.count > Self.maximumEntries {
            entries.removeLast(entries.count - Self.maximumEntries)
        }
        schedulePersist()
    }

    func remove(_ entry: ListeningHistoryEntry) {
        let originalCount = entries.count
        entries.removeAll { $0.id == entry.id }
        if entries.count != originalCount {
            schedulePersist()
        }
    }

    func clear() {
        entries = []
        saveTask?.cancel()
        saveTask = nil
        if let key { defaults.removeObject(forKey: key) }
    }

    private func schedulePersist() {
        guard let key else { return }
        let snapshot = entries
        saveTask?.cancel()
        saveTask = Task { [weak self, snapshot] in
            do {
                try await Task.sleep(nanoseconds: Self.saveDebounceNanoseconds)
            } catch {
                return
            }
            let data = await Self.encodedData(for: snapshot)
            guard !Task.isCancelled, let data, let self, self.key == key else { return }
            self.defaults.set(data, forKey: key)
        }
    }

    private nonisolated static func encodedData(
        for entries: [ListeningHistoryEntry]
    ) async -> Data? {
        await Task.detached(priority: .utility) {
            try? JSONEncoder().encode(entries)
        }.value
    }
}
