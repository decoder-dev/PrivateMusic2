import Foundation

@MainActor
final class HomeCatalogStore: ObservableObject {
    static let staleInterval: TimeInterval = 15 * 60

    @Published private(set) var recommendations: [Track] = []
    @Published private(set) var mixes: [MusicMix] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshedAt: Date?
    @Published var errorMessage: String?
    private var accountID: Int?
    private var lastAttemptedAt: Date?
    private var refreshGeneration = 0

    var isEmpty: Bool {
        recommendations.isEmpty && mixes.isEmpty && playlists.isEmpty
    }

    func prepare(accountID: Int?) {
        guard self.accountID != accountID else { return }
        self.accountID = accountID
        refreshGeneration += 1
        recommendations = []
        mixes = []
        playlists = []
        lastRefreshedAt = nil
        lastAttemptedAt = nil
        errorMessage = nil
        isRefreshing = false
    }

    func shouldRefresh(force: Bool, now: Date = Date()) -> Bool {
        guard !isRefreshing else { return false }
        guard !force else { return true }
        guard !isEmpty,
              let freshnessDate = lastRefreshedAt ?? lastAttemptedAt else {
            return true
        }
        return now.timeIntervalSince(freshnessDate) >= Self.staleInterval
    }

    func beginRefreshing() -> Int {
        isRefreshing = true
        refreshGeneration += 1
        return refreshGeneration
    }

    func finish(
        recommendations: [Track]?,
        mixes: [MusicMix]?,
        playlists: [Playlist]?,
        errorMessage: String?,
        refreshID: Int? = nil,
        now: Date = Date()
    ) {
        guard refreshID == nil || refreshID == refreshGeneration else {
            return
        }
        if let recommendations { self.recommendations = recommendations }
        if let mixes { self.mixes = mixes }
        if let playlists { self.playlists = playlists }
        self.errorMessage = errorMessage
        lastAttemptedAt = now
        if errorMessage == nil {
            lastRefreshedAt = now
        }
        isRefreshing = false
    }

    func cancelRefreshing(refreshID: Int? = nil) {
        guard refreshID == nil || refreshID == refreshGeneration else {
            return
        }
        isRefreshing = false
    }
}
