import Foundation

enum SearchViewState: Equatable {
    case idle
    case needsMoreCharacters
    case loading
    case results
    case empty
    case failure(String)
}

@MainActor
final class SearchViewModel: ObservableObject {
    typealias SearchOperation =
        (String, Int, Int) async throws -> MusicPage<Track>
    typealias AddOperation = (Track) async throws -> Track

    static let minimumQueryLength = 2

    @Published var query = ""
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var recentQueries: [String]
    @Published private(set) var errorMessage: String?
    @Published private(set) var paginationErrorMessage: String?
    @Published var actionErrorMessage: String?

    private var searchTask: Task<Void, Never>?
    private var searchRevision = 0
    private var nextOffset: Int?
    private var activeQuery = ""
    private let defaults: UserDefaults
    private let historyKey = "search.recent.queries.v1"
    private let debounceDuration: Duration

    init(
        defaults: UserDefaults = .standard,
        debounceDuration: Duration = .milliseconds(320)
    ) {
        self.defaults = defaults
        self.debounceDuration = debounceDuration
        recentQueries = Self.normalizedHistory(
            defaults.stringArray(forKey: historyKey) ?? []
        )
    }

    var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var state: SearchViewState {
        if normalizedQuery.isEmpty {
            return .idle
        }
        if normalizedQuery.count < Self.minimumQueryLength {
            return .needsMoreCharacters
        }
        if isLoading, tracks.isEmpty {
            return .loading
        }
        if !tracks.isEmpty {
            return .results
        }
        if let errorMessage {
            return .failure(errorMessage)
        }
        if activeQuery == normalizedQuery {
            return .empty
        }
        return .idle
    }

    var artists: [String] {
        var seen = Set<String>()
        return tracks.compactMap { track in
            let name = track.artist.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let key = name.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            .lowercased()
            guard !name.isEmpty, seen.insert(key).inserted else {
                return nil
            }
            return name
        }
    }

    func schedule(
        operation: @escaping SearchOperation
    ) {
        beginSearch(
            delay: debounceDuration,
            operation: operation
        )
    }

    func submit(
        operation: @escaping SearchOperation
    ) {
        beginSearch(delay: .zero, operation: operation)
    }

    private func beginSearch(
        delay: Duration,
        operation: @escaping SearchOperation
    ) {
        searchTask?.cancel()
        searchRevision += 1
        let revision = searchRevision
        let requestedQuery = normalizedQuery

        isLoadingMore = false
        paginationErrorMessage = nil
        errorMessage = nil
        guard requestedQuery.count >= Self.minimumQueryLength else {
            tracks = []
            nextOffset = nil
            activeQuery = ""
            isLoading = false
            return
        }

        if requestedQuery != activeQuery {
            tracks = []
            nextOffset = nil
        }
        isLoading = true
        searchTask = Task {
            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
                await search(
                    requestedQuery,
                    revision: revision,
                    operation: operation
                )
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func search(
        _ requestedQuery: String,
        revision: Int,
        operation: SearchOperation
    ) async {
        guard revision == searchRevision else { return }
        defer {
            if revision == searchRevision {
                isLoading = false
            }
        }
        do {
            let page = try await operation(requestedQuery, 0, 100)
            guard revision == searchRevision, !Task.isCancelled else {
                return
            }
            tracks = Self.uniqueTracks(page.items)
            nextOffset = page.nextOffset
            activeQuery = requestedQuery
            if !tracks.isEmpty {
                record(requestedQuery)
            }
            errorMessage = nil
        } catch {
            guard revision == searchRevision, !Task.isCancelled else {
                return
            }
            if Self.isCancellation(error) {
                activeQuery = ""
                errorMessage = nil
                return
            }
            activeQuery = requestedQuery
            errorMessage = error.localizedDescription
        }
    }

    func loadMore(
        operation: SearchOperation
    ) async {
        let requestedQuery = normalizedQuery
        guard requestedQuery == activeQuery,
              !isLoading,
              !isLoadingMore,
              let offset = nextOffset else {
            return
        }
        let revision = searchRevision
        isLoadingMore = true
        paginationErrorMessage = nil
        defer {
            if revision == searchRevision {
                isLoadingMore = false
            }
        }
        do {
            let page = try await operation(requestedQuery, offset, 100)
            guard revision == searchRevision, !Task.isCancelled else {
                return
            }
            tracks.append(
                contentsOf: Self.uniqueTracks(
                    page.items,
                    excluding: Set(tracks.map(\.id))
                )
            )
            nextOffset = page.nextOffset
        } catch {
            guard revision == searchRevision,
                  !Task.isCancelled,
                  !Self.isCancellation(error) else {
                return
            }
            paginationErrorMessage = error.localizedDescription
        }
    }

    func useRecent(_ value: String) {
        query = value
    }

    func removeRecent(_ value: String) {
        recentQueries.removeAll {
            $0.localizedCaseInsensitiveCompare(value) == .orderedSame
        }
        persistHistory()
    }

    func clearRecent() {
        recentQueries = []
        defaults.removeObject(forKey: historyKey)
    }

    func add(
        _ track: Track,
        operation: AddOperation
    ) async -> Track? {
        do {
            let added = try await operation(track)
            MusicLibraryEvents.postAdded(added)
            actionErrorMessage = nil
            return added
        } catch is CancellationError {
            return nil
        } catch {
            actionErrorMessage = error.localizedDescription
            return nil
        }
    }

    static func normalizedHistory(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values {
            let cleaned = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard cleaned.count >= minimumQueryLength,
                  !result.contains(where: {
                      $0.localizedCaseInsensitiveCompare(cleaned)
                          == .orderedSame
                  }) else {
                continue
            }
            result.append(cleaned)
            if result.count == 10 {
                break
            }
        }
        return result
    }

    private func record(_ value: String) {
        recentQueries.removeAll {
            $0.localizedCaseInsensitiveCompare(value) == .orderedSame
        }
        recentQueries.insert(value, at: 0)
        recentQueries = Array(recentQueries.prefix(10))
        persistHistory()
    }

    private func persistHistory() {
        defaults.set(recentQueries, forKey: historyKey)
    }

    private static func uniqueTracks(
        _ tracks: [Track],
        excluding excludedIDs: Set<String> = []
    ) -> [Track] {
        var known = excludedIDs
        return tracks.filter { known.insert($0.id).inserted }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError,
           urlError.code == .cancelled {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code == NSURLErrorCancelled
    }
}
