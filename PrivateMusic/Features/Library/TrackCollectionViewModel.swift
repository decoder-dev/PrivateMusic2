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
    private var service: any MusicService

    init(source: Source, service: any MusicService) {
        self.source = source
        self.service = service
    }

    func configure(service: any MusicService) {
        self.service = service
    }

    func load(accessToken: String, force: Bool = false) async {
        guard !isLoading, force || tracks.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            switch source {
            case .library:
                tracks = try await service.library(
                    accessToken: accessToken,
                    offset: 0
                )
            case .recommendations:
                tracks = try await service.recommendations(
                    accessToken: accessToken
                )
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
