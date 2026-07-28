import Foundation

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private var searchTask: Task<Void, Never>?

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
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 2 else {
            tracks = []
            errorMessage = nil
            return
        }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await search(
                normalized,
                service: service,
                accessToken: accessToken
            )
        }
    }

    private func search(
        _ query: String,
        service: any MusicService,
        accessToken: String
    ) async {
        isLoading = true
        defer { isLoading = false }
        do {
            tracks = try await service.search(
                query: query,
                accessToken: accessToken,
                offset: 0,
                count: 100
            ).items
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
