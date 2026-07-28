import Foundation

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var isLoading = false
    @Published private(set) var recentQueries: [String]
    @Published var errorMessage: String?

    private var searchTask: Task<Void, Never>?
    private var searchRevision = 0
    private let defaults: UserDefaults
    private let historyKey = "search.recent.queries.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recentQueries = defaults.stringArray(forKey: historyKey) ?? []
    }

    var artists: [String] {
        var seen = Set<String>()
        return tracks.compactMap { track in
            let name = track.artist.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let key = name.lowercased()
            guard !name.isEmpty, seen.insert(key).inserted else {
                return nil
            }
            return name
        }
    }

    func schedule(
        service: any MusicService,
        accessToken: String
    ) {
        searchTask?.cancel()
        searchRevision += 1
        let revision = searchRevision
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 2 else {
            tracks = []
            errorMessage = nil
            isLoading = false
            return
        }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await search(
                normalized,
                revision: revision,
                service: service,
                accessToken: accessToken
            )
        }
    }

    private func search(
        _ query: String,
        revision: Int,
        service: any MusicService,
        accessToken: String
    ) async {
        guard revision == searchRevision else { return }
        isLoading = true
        defer {
            if revision == searchRevision {
                isLoading = false
            }
        }
        do {
            let results = try await service.search(
                query: query,
                accessToken: accessToken,
                offset: 0,
                count: 100
            ).items
            guard revision == searchRevision, !Task.isCancelled else {
                return
            }
            tracks = results
            if !tracks.isEmpty {
                record(query)
            }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard revision == searchRevision, !Task.isCancelled else {
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    func useRecent(_ value: String) {
        query = value
    }

    func removeRecent(_ value: String) {
        recentQueries.removeAll { $0 == value }
        defaults.set(recentQueries, forKey: historyKey)
    }

    func clearRecent() {
        recentQueries = []
        defaults.removeObject(forKey: historyKey)
    }

    private func record(_ value: String) {
        recentQueries.removeAll {
            $0.localizedCaseInsensitiveCompare(value) == .orderedSame
        }
        recentQueries.insert(value, at: 0)
        recentQueries = Array(recentQueries.prefix(10))
        defaults.set(recentQueries, forKey: historyKey)
    }

    func add(
        _ track: Track,
        service: any MusicService,
        accessToken: String
    ) async {
        do {
            try await service.addToLibrary(
                track,
                accessToken: accessToken
            )
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
