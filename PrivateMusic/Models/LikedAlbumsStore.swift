import Foundation

@MainActor
final class LikedAlbumsStore: ObservableObject {
    @Published private(set) var albums: [Album] = []
    private var accountID: Int?
    private var localOverrides: [String: Bool] = [:]
    private var isSynchronized = false
    private var refreshGeneration = 0

    func prepare(accountID: Int?) {
        guard self.accountID != accountID else { return }
        self.accountID = accountID
        albums = []
        localOverrides = [:]
        isSynchronized = false
        refreshGeneration += 1
    }

    func contains(_ album: Album) -> Bool {
        albums.contains { $0.compositeID == album.compositeID }
    }

    func isFollowed(_ album: Album) -> Bool {
        if let override = localOverrides[album.compositeID] {
            return override
        }
        return contains(album) || (!isSynchronized && album.isFollowed)
    }

    /// Callers must fetch the full remote list, then pass this ID back to
    /// `replace(with:refreshID:)`. Concurrent refreshes (multiple screens
    /// refresh on the same account-login trigger) and local follow/unfollow
    /// actions all bump the generation, so a slower, older fetch can no
    /// longer clobber a newer one or a user's in-flight local change.
    func beginRefresh() -> Int {
        refreshGeneration += 1
        return refreshGeneration
    }

    func replace(with albums: [Album], refreshID: Int) {
        guard refreshID == refreshGeneration else { return }
        var seen = Set<String>()
        self.albums = albums.filter { seen.insert($0.compositeID).inserted }
        localOverrides = [:]
        isSynchronized = true
    }

    func markFollowed(_ album: Album) {
        refreshGeneration += 1
        albums.removeAll { $0.compositeID == album.compositeID }
        albums.insert(album.updatingFollowed(true), at: 0)
        localOverrides[album.compositeID] = true
    }

    func markUnfollowed(_ album: Album) {
        refreshGeneration += 1
        albums.removeAll { $0.compositeID == album.compositeID }
        localOverrides[album.compositeID] = false
    }
}

extension Notification.Name {
    static let likedAlbumsDidChange = Notification.Name(
        "PrivateMusic.likedAlbumsDidChange"
    )
}
