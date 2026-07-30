import Foundation

@MainActor
final class TrackCollectionViewModel: ObservableObject {
    enum Source {
        case library
        case recommendations
    }

    @Published private(set) var tracks: [Track] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var totalCount = 0
    @Published var errorMessage: String?

    private let source: Source
    private var service: (any MusicService)?
    private var nextOffset: Int?

    init(source: Source) {
        self.source = source
    }

    func configure(service: any MusicService) {
        self.service = service
    }

    func load(
        force: Bool = false,
        operation: () async throws -> MusicPage<Track>
    ) async {
        guard !isLoading, force || tracks.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let page = try await operation()
            tracks = page.items
            totalCount = page.totalCount
            nextOffset = page.nextOffset
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMore(
        operation: (Int) async throws -> MusicPage<Track>
    ) async {
        guard source == .library,
              !isLoading,
              !isLoadingMore,
              let offset = nextOffset else {
            return
        }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await operation(offset)
            appendUnique(page.items)
            totalCount = page.totalCount
            nextOffset = page.nextOffset
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func remove(_ track: Track, accessToken: String) async -> Bool {
        guard source == .library, let service else { return false }
        do {
            try await service.removeFromLibrary(
                track,
                accessToken: accessToken
            )
            tracks.removeAll { $0.id == track.id }
            totalCount = max(totalCount - 1, 0)
            errorMessage = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func insertAdded(_ track: Track) {
        guard source == .library else { return }
        tracks.removeAll { $0.id == track.id }
        tracks.insert(track, at: 0)
        errorMessage = nil
    }

    func removeLocally(_ track: Track) {
        guard source == .library else { return }
        tracks.removeAll { $0.id == track.id }
        totalCount = max(totalCount - 1, 0)
        errorMessage = nil
    }

    private func appendUnique(_ additions: [Track]) {
        var known = Set(tracks.map(\.id))
        tracks.append(contentsOf: additions.filter {
            known.insert($0.id).inserted
        })
    }
}
