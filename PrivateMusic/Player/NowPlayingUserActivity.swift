import Foundation

/// Handoff / Spotlight payload for the track that is playing on this device.
/// The activity type is declared in Info.plist `NSUserActivityTypes`.
enum NowPlayingUserActivityPolicy {
    static let activityType = "com.dec.privatemusic2.now-playing"
    static let trackIDKey = "trackID"
    static let titleKey = "title"
    static let artistKey = "artist"

    static func userInfo(for track: Track) -> [String: String] {
        [
            trackIDKey: track.id,
            titleKey: track.title,
            artistKey: track.artist
        ]
    }

    static func activityTitle(for track: Track) -> String {
        let artist = track.artist.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let title = track.title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if artist.isEmpty { return title }
        if title.isEmpty { return artist }
        return "\(artist) — \(title)"
    }

    static func trackID(
        fromUserInfo userInfo: [AnyHashable: Any]?
    ) -> String? {
        userInfo?[trackIDKey] as? String
    }

    /// Opens the full-screen player when the phone already has a current
    /// track — Handoff/Spotlight are a "show me what's playing" gesture.
    static func shouldPresentPlayer(currentTrackID: String?) -> Bool {
        currentTrackID != nil
    }

    /// If the handed-off track is still in the restored queue, jump to it
    /// instead of leaving a different snapshot on screen.
    static func queueIndexToResume(
        activityTrackID: String?,
        queueIDs: [String],
        currentIndex: Int?
    ) -> Int? {
        guard let activityTrackID,
              let index = queueIDs.firstIndex(of: activityTrackID) else {
            return nil
        }
        if currentIndex == index { return nil }
        return index
    }
}
