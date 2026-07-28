import Foundation

enum MusicLibraryEvents {
    static let didAddTrack = Notification.Name(
        "PrivateMusic.MusicLibrary.didAddTrack"
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
}
