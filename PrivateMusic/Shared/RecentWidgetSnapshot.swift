import Foundation

struct RecentWidgetTrack: Codable, Identifiable {
    let id: String
    let title: String
    let artist: String
    let artwork: Data?
}

struct RecentWidgetSnapshot: Codable {
    static let group = "group.com.dec.privatemusic2"
    static let kind = "PrivateMusicRecent"
    let accountID: Int?
    let tracks: [RecentWidgetTrack]

    static var file: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("recent-widget.json")
    }

    static func read() -> RecentWidgetSnapshot {
        guard let file, let data = try? Data(contentsOf: file),
              let snapshot = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self(accountID: nil, tracks: [])
        }
        return snapshot
    }

    func url(for track: RecentWidgetTrack) -> URL? {
        guard let accountID else { return nil }
        var components = URLComponents()
        components.scheme = "privatemusic"
        components.host = "recent"
        components.queryItems = [URLQueryItem(name: "track", value: track.id),
                                 URLQueryItem(name: "account", value: String(accountID))]
        return components.url
    }
}
