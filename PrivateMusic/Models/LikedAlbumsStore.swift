import Foundation

@MainActor
final class LikedAlbumsStore: ObservableObject {
    @Published private(set) var albums: [Album] = []
    private var accountID: Int?
    private var localOverrides: [String: Bool] = [:]
    private var isSynchronized = false

    func prepare(accountID: Int?) {
        guard self.accountID != accountID else { return }
        self.accountID = accountID
        albums = []
        localOverrides = [:]
        isSynchronized = false
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

    func replace(with albums: [Album]) {
        var seen = Set<String>()
        self.albums = albums.filter { seen.insert($0.compositeID).inserted }
        localOverrides = [:]
        isSynchronized = true
    }

    func markFollowed(_ album: Album) {
        albums.removeAll { $0.compositeID == album.compositeID }
        albums.insert(album.updatingFollowed(true), at: 0)
        localOverrides[album.compositeID] = true
    }

    func markUnfollowed(_ album: Album) {
        albums.removeAll { $0.compositeID == album.compositeID }
        localOverrides[album.compositeID] = false
    }
}

extension Notification.Name {
    static let likedAlbumsDidChange = Notification.Name(
        "PrivateMusic.likedAlbumsDidChange"
    )
}
