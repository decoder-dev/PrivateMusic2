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
    typealias AlbumSearchOperation =
        (String, Int, Int) async throws -> MusicPage<Album>
    typealias PlaylistSearchOperation =
        (String, Int, Int) async throws -> MusicPage<Playlist>
    typealias AddOperation = (Track) async throws -> Track

    static let minimumQueryLength = 2

    @Published var query = ""
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var albums: [Album] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var isLoadingAlbums = false
    @Published private(set) var isLoadingMoreAlbums = false
    @Published private(set) var isLoadingPlaylists = false
    @Published private(set) var isLoadingMorePlaylists = false
    @Published var albumErrorMessage: String?
    @Published var playlistErrorMessage: String?
    @Published private(set) var recentQueries: [String]
    @Published private(set) var errorMessage: String?
    @Published private(set) var paginationErrorMessage: String?
    @Published var actionErrorMessage: String?

    private var searchTask: Task<Void, Never>?
    private var albumSearchTask: Task<Void, Never>?
    private var playlistSearchTask: Task<Void, Never>?
    private var searchRevision = 0
    private var nextOffset: Int?
    private var activeQuery = ""
    private var albumSearchRevision = 0
    private var albumNextOffset: Int?
    private var activeAlbumQuery = ""
    private var playlistSearchRevision = 0
    private var playlistNextOffset: Int?
    private var activePlaylistQuery = ""
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
        if (isLoading || isLoadingAlbums || isLoadingPlaylists),
           tracks.isEmpty,
           albums.isEmpty,
           playlists.isEmpty {
            return .loading
        }
        if !tracks.isEmpty || !albums.isEmpty || !playlists.isEmpty {
            return .results
        }
        if let message = errorMessage ?? albumErrorMessage
            ?? playlistErrorMessage {
            return .failure(message)
        }
        if activeQuery == normalizedQuery
            || activeAlbumQuery == normalizedQuery
            || activePlaylistQuery == normalizedQuery {
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

    func scheduleAlbums(operation: @escaping AlbumSearchOperation) {
        beginAlbumSearch(delay: debounceDuration, operation: operation)
    }

    func submitAlbums(operation: @escaping AlbumSearchOperation) {
        beginAlbumSearch(delay: .zero, operation: operation)
    }

    func schedulePlaylists(operation: @escaping PlaylistSearchOperation) {
        beginPlaylistSearch(delay: debounceDuration, operation: operation)
    }

    func submitPlaylists(operation: @escaping PlaylistSearchOperation) {
        beginPlaylistSearch(delay: .zero, operation: operation)
    }

    private func beginAlbumSearch(
        delay: Duration,
        operation: @escaping AlbumSearchOperation
    ) {
        albumSearchTask?.cancel()
        albumSearchRevision += 1
        let revision = albumSearchRevision
        let requestedQuery = normalizedQuery
        albumErrorMessage = nil
        isLoadingMoreAlbums = false
        guard requestedQuery.count >= Self.minimumQueryLength else {
            albums = []
            albumNextOffset = nil
            activeAlbumQuery = ""
            isLoadingAlbums = false
            return
        }
        if requestedQuery != activeAlbumQuery {
            albums = []
            albumNextOffset = nil
        }
        isLoadingAlbums = true
        albumSearchTask = Task {
            do {
                try await Task.sleep(for: delay)
                let page = try await operation(requestedQuery, 0, 50)
                guard revision == albumSearchRevision,
                      !Task.isCancelled else { return }
                albums = Self.uniqueAlbums(page.items)
                albumNextOffset = page.nextOffset
                activeAlbumQuery = requestedQuery
                albumErrorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                guard revision == albumSearchRevision else { return }
                activeAlbumQuery = requestedQuery
                albumErrorMessage = error.localizedDescription
            }
            if revision == albumSearchRevision {
                isLoadingAlbums = false
            }
        }
    }

    func loadMoreAlbums(operation: AlbumSearchOperation) async {
        let requestedQuery = normalizedQuery
        guard requestedQuery == activeAlbumQuery,
              !isLoadingAlbums,
              !isLoadingMoreAlbums,
              let offset = albumNextOffset else { return }
        isLoadingMoreAlbums = true
        let revision = albumSearchRevision
        defer { isLoadingMoreAlbums = false }
        do {
            let page = try await operation(requestedQuery, offset, 50)
            guard revision == albumSearchRevision,
                  requestedQuery == activeAlbumQuery,
                  !Task.isCancelled else {
                return
            }
            albums.append(
                contentsOf: Self.uniqueAlbums(
                    page.items,
                    excluding: Set(albums.map(\.compositeID))
                )
            )
            albumNextOffset = page.nextOffset
            albumErrorMessage = nil
        } catch {
            guard revision == albumSearchRevision,
                  !Self.isCancellation(error) else { return }
            albumErrorMessage = error.localizedDescription
        }
    }

    private func beginPlaylistSearch(
        delay: Duration,
        operation: @escaping PlaylistSearchOperation
    ) {
        playlistSearchTask?.cancel()
        playlistSearchRevision += 1
        let revision = playlistSearchRevision
        let requestedQuery = normalizedQuery
        playlistErrorMessage = nil
        isLoadingMorePlaylists = false
        guard requestedQuery.count >= Self.minimumQueryLength else {
            playlists = []
            playlistNextOffset = nil
            activePlaylistQuery = ""
            isLoadingPlaylists = false
            return
        }
        if requestedQuery != activePlaylistQuery {
            playlists = []
            playlistNextOffset = nil
        }
        isLoadingPlaylists = true
        playlistSearchTask = Task {
            do {
                try await Task.sleep(for: delay)
                let page = try await operation(requestedQuery, 0, 100)
                guard revision == playlistSearchRevision,
                      !Task.isCancelled else { return }
                playlists = Self.uniquePlaylists(page.items)
                playlistNextOffset = page.nextOffset
                activePlaylistQuery = requestedQuery
                if !playlists.isEmpty {
                    record(requestedQuery)
                }
                playlistErrorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                guard revision == playlistSearchRevision else { return }
                activePlaylistQuery = requestedQuery
                playlistErrorMessage = error.localizedDescription
            }
            if revision == playlistSearchRevision {
                isLoadingPlaylists = false
            }
        }
    }

    func loadMorePlaylists(operation: PlaylistSearchOperation) async {
        let requestedQuery = normalizedQuery
        guard requestedQuery == activePlaylistQuery,
              !isLoadingPlaylists,
              !isLoadingMorePlaylists,
              let offset = playlistNextOffset else { return }
        isLoadingMorePlaylists = true
        let revision = playlistSearchRevision
        defer { isLoadingMorePlaylists = false }
        do {
            let page = try await operation(requestedQuery, offset, 100)
            guard revision == playlistSearchRevision,
                  requestedQuery == activePlaylistQuery,
                  !Task.isCancelled else {
                return
            }
            playlists.append(
                contentsOf: Self.uniquePlaylists(
                    page.items,
                    excluding: Set(playlists.map(Self.playlistIdentity))
                )
            )
            playlistNextOffset = page.nextOffset
            playlistErrorMessage = nil
        } catch {
            guard revision == playlistSearchRevision,
                  !Self.isCancellation(error) else { return }
            playlistErrorMessage = error.localizedDescription
        }
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
            albumSearchTask?.cancel()
            albums = []
            albumNextOffset = nil
            activeAlbumQuery = ""
            albumErrorMessage = nil
            playlists = []
            playlistNextOffset = nil
            activePlaylistQuery = ""
            playlistErrorMessage = nil
            isLoading = false
            isLoadingAlbums = false
            isLoadingPlaylists = false
            return
        }

        if requestedQuery != activeQuery {
            tracks = []
            nextOffset = nil
        }
        if requestedQuery != activeAlbumQuery {
            albumSearchTask?.cancel()
            albums = []
            albumNextOffset = nil
            activeAlbumQuery = ""
            albumErrorMessage = nil
            isLoadingAlbums = false
        }
        if requestedQuery != activePlaylistQuery {
            playlistSearchTask?.cancel()
            playlists = []
            playlistNextOffset = nil
            activePlaylistQuery = ""
            playlistErrorMessage = nil
            isLoadingPlaylists = false
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

    private static func uniqueAlbums(
        _ albums: [Album],
        excluding excludedIDs: Set<String> = []
    ) -> [Album] {
        var known = excludedIDs
        return albums.filter { known.insert($0.compositeID).inserted }
    }

    private static func uniquePlaylists(
        _ playlists: [Playlist],
        excluding excludedIDs: Set<String> = []
    ) -> [Playlist] {
        var known = excludedIDs
        return playlists.filter {
            known.insert(playlistIdentity($0)).inserted
        }
    }

    private static func playlistIdentity(_ playlist: Playlist) -> String {
        playlist.libraryIdentity
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
