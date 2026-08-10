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
    private var loadGeneration = 0
    private var optimisticAdditions: [Track] = []

    init(source: Source) {
        self.source = source
    }

    func configure(service: any MusicService) {
        self.service = service
    }

    /// Returns `true` only when a fresh page was applied. Concurrent force
    /// reloads bump a generation so a slower response cannot clobber a newer
    /// one or wipe a successful load with an empty early-return path.
    @discardableResult
    func load(
        force: Bool = false,
        operation: () async throws -> MusicPage<Track>
    ) async -> Bool {
        if isLoading {
            guard force else { return false }
        } else if !force && !tracks.isEmpty {
            return false
        }

        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer {
            if generation == loadGeneration {
                isLoading = false
            }
        }

        do {
            let page = try await operation()
            guard generation == loadGeneration else { return false }
            let missingOptimisticCount = missingOptimisticAdditions(
                from: page.items
            )
            tracks = mergedFirstPage(page.items)
            totalCount = page.totalCount + missingOptimisticCount
            nextOffset = page.nextOffset
            errorMessage = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard generation == loadGeneration else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func loadMore(
        operation: (Int) async throws -> MusicPage<Track>
    ) async -> Bool {
        guard source == .library,
              !isLoading,
              !isLoadingMore,
              let offset = nextOffset else {
            return false
        }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await operation(offset)
            appendUnique(page.items)
            totalCount = page.totalCount
            nextOffset = page.nextOffset
            errorMessage = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func remove(_ track: Track, accessToken: String) async -> Bool {
        guard source == .library, let service else { return false }
        do {
            try await service.removeFromLibrary(
                track,
                accessToken: accessToken
            )
            invalidateLoadsForLocalMutation()
            optimisticAdditions.removeAll { $0.id == track.id }
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
        invalidateLoadsForLocalMutation()
        optimisticAdditions.removeAll { $0.id == track.id }
        optimisticAdditions.insert(track, at: 0)
        let existed = tracks.contains { $0.id == track.id }
        tracks.removeAll { $0.id == track.id }
        tracks.insert(track, at: 0)
        if !existed {
            totalCount += 1
        }
        errorMessage = nil
    }

    func removeLocally(_ track: Track) {
        guard source == .library else { return }
        invalidateLoadsForLocalMutation()
        optimisticAdditions.removeAll { $0.id == track.id }
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

    private func invalidateLoadsForLocalMutation() {
        loadGeneration += 1
        isLoading = false
    }

    private func mergedFirstPage(_ pageItems: [Track]) -> [Track] {
        guard source == .library,
              !optimisticAdditions.isEmpty else {
            return pageItems
        }
        var merged: [Track] = []
        var known = Set<String>()
        for track in optimisticAdditions + pageItems
            where known.insert(track.id).inserted {
            merged.append(track)
        }
        optimisticAdditions.removeAll()
        return merged
    }

    private func missingOptimisticAdditions(from pageItems: [Track]) -> Int {
        guard source == .library,
              !optimisticAdditions.isEmpty else {
            return 0
        }
        let pageIDs = Set(pageItems.map(\.id))
        return optimisticAdditions.filter { !pageIDs.contains($0.id) }.count
    }
}
