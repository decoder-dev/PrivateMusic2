import Foundation

struct DemoMusicService: MusicService {
    private let tracks: [Track]

    init() {
        let demoURL = Bundle.main.url(
            forResource: "DemoTone",
            withExtension: "wav"
        )
        tracks = [
            Track(
                trackID: 1,
                ownerID: 0,
                title: "Midnight Signal",
                artist: "Private Music",
                duration: 12,
                streamURL: demoURL,
                artworkURL: nil
            ),
            Track(
                trackID: 2,
                ownerID: 0,
                title: "No Trace",
                artist: "Blue Static",
                duration: 12,
                streamURL: demoURL,
                artworkURL: nil
            ),
            Track(
                trackID: 3,
                ownerID: 0,
                title: "After Dark",
                artist: "Violet Shield",
                duration: 12,
                streamURL: demoURL,
                artworkURL: nil
            )
        ]
    }

    func profile(accessToken: String) async throws -> UserProfile {
        UserProfile(
            id: 1,
            firstName: "Private",
            lastName: "Listener",
            photoURL: nil
        )
    }

    func library(accessToken: String, offset: Int) async throws -> [Track] {
        tracks
    }

    func recommendations(accessToken: String) async throws -> [Track] {
        Array(tracks.reversed())
    }

    func search(
        query: String,
        accessToken: String,
        offset: Int
    ) async throws -> [Track] {
        guard !query.isEmpty else { return [] }
        return tracks.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.artist.localizedCaseInsensitiveContains(query)
        }
    }
}
