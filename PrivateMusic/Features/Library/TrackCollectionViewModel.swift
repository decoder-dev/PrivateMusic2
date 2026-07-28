import Foundation

@MainActor
final class TrackCollectionViewModel: ObservableObject {
    enum Source {
        case library
        case recommendations
    }

    @Published private(set) var tracks: [Track] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let source: Source
    private var service: (any MusicService)?

    init(source: Source) {
        self.source = source
    }

    func configure(service: any MusicService) {
        self.service = service
    }

    func load(accessToken: String, force: Bool = false) async {
        guard !isLoading, force || tracks.isEmpty else { return }
        guard let service else {
            errorMessage = "Музыкальный сервис ещё не готов."
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            switch source {
            case .library:
                tracks = try await service.library(
                    accessToken: accessToken,
                    offset: 0,
                    count: 100
                ).items
            case .recommendations:
                tracks = try await service.recommendations(
                    accessToken: accessToken
                )
            }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func remove(_ track: Track, accessToken: String) async {
        guard source == .library, let service else { return }
        do {
            try await service.removeFromLibrary(
                track,
                accessToken: accessToken
            )
            tracks.removeAll { $0.id == track.id }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func insertAdded(_ track: Track) {
        guard source == .library else { return }
        tracks.removeAll { $0.id == track.id }
        tracks.insert(track, at: 0)
        errorMessage = nil
    }
}
