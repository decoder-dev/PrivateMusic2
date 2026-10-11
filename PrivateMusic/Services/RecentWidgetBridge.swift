import UIKit
import WidgetKit

@MainActor
enum RecentWidgetBridge {
    static func publish(_ entries: [ListeningHistoryEntry], accountID: Int?) {
        guard let file = RecentWidgetSnapshot.file else { return }
        let tracks: [RecentWidgetTrack] = accountID == nil ? [] : entries.prefix(3).map { entry in
            let artwork = entry.track.artworkURL.flatMap { url in
                ArtworkImageCache.shared.image(for: url, maxPixelSize: 128)
                    ?? ArtworkImageCache.shared.image(for: url, maxPixelSize: 256)
            }?.jpegData(compressionQuality: 0.75)
            return RecentWidgetTrack(id: entry.track.id, title: entry.track.title,
                                     artist: entry.track.artist, artwork: artwork)
        }
        let snapshot = RecentWidgetSnapshot(accountID: accountID, tracks: tracks)
        do {
            try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
            WidgetCenter.shared.reloadTimelines(ofKind: RecentWidgetSnapshot.kind)
        } catch { AppLog.shared.failure(.app, "Update recent widget", error) }
    }
}
