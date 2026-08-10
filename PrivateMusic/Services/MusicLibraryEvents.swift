import Foundation

enum MusicLibraryEvents {
    static let didAddTrack = Notification.Name(
        "PrivateMusic.MusicLibrary.didAddTrack"
    )
    static let didRemoveTrack = Notification.Name(
        "PrivateMusic.MusicLibrary.didRemoveTrack"
    )
    static let didChangePlaylists = Notification.Name(
        "PrivateMusic.MusicLibrary.didChangePlaylists"
    )
    static let trackKey = "track"
    static let playlistKey = "playlist"

    @MainActor
    static func postAdded(_ track: Track) {
        NotificationCenter.default.post(
            name: didAddTrack,
            object: nil,
            userInfo: [trackKey: track]
        )
    }

    @MainActor
    static func postRemoved(_ track: Track) {
        NotificationCenter.default.post(
            name: didRemoveTrack,
            object: nil,
            userInfo: [trackKey: track]
        )
    }

    @MainActor
    static func postPlaylistsChanged(removed playlist: Playlist? = nil) {
        var userInfo: [AnyHashable: Any] = [:]
        if let playlist {
            userInfo[playlistKey] = playlist
        }
        NotificationCenter.default.post(
            name: didChangePlaylists,
            object: nil,
            userInfo: userInfo.isEmpty ? nil : userInfo
        )
    }
}
