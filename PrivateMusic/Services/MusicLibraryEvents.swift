import Foundation

enum MusicLibraryEvents {
    static let didAddTrack = Notification.Name(
        "PrivateMusic.MusicLibrary.didAddTrack"
    )
    static let didRemoveTrack = Notification.Name(
        "PrivateMusic.MusicLibrary.didRemoveTrack"
    )
    static let trackKey = "track"

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
}
