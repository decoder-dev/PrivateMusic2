import Foundation

struct VKMusicService: MusicService {
    private let client: APIClient
    private let apiVersion: String
    private let context: VKMusicContext
    private let lyricsService = LRCLyricsService()

    init(
        client: APIClient,
        apiVersion: String,
        initialUserID: Int? = nil
    ) {
        self.client = client
        self.apiVersion = apiVersion
        self.context = VKMusicContext(userID: initialUserID)
    }

    func configure(userAgent: String?) async {
        await client.setUserAgent(userAgent)
    }

    func profile(accessToken: String) async throws -> UserProfile {
        let envelope: VKResponse<[UserProfile]> = try await client.post(
            path: "/method/users.get",
            form: common(accessToken).merging([
                "fields": "photo_200"
            ]) { _, new in new },
            responseType: VKResponse<[UserProfile]>.self
        )
        guard let profile = envelope.response.first else {
            throw APIError.invalidResponse
        }
        await context.setUserID(profile.id)
        return profile
    }

    func library(
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Track> {
        let envelope: VKResponse<VKItems<Track>> = try await client.post(
            path: "/method/audio.get",
            form: common(accessToken).merging([
                "count": String(count),
                "offset": String(offset)
            ]) { _, new in new },
            responseType: VKResponse<VKItems<Track>>.self
        )
        let userID = await context.userID
        let resolved = VKItems(
            count: envelope.response.count,
            items: envelope.response.items.map {
                $0.resolvingStreamURL(userID: userID)
            }
        )
        return page(resolved, offset: offset, requested: count)
    }

    func recommendations(accessToken: String) async throws -> [Track] {
        do {
            let envelope: VKResponse<VKItems<Track>> = try await client.post(
                path: "/method/audio.getRecommendations",
                form: common(accessToken).merging([
                    "count": "100",
                    "shuffle": "1"
                ]) { _, new in new },
                responseType: VKResponse<VKItems<Track>>.self
            )
            let userID = await context.userID
            let tracks = envelope.response.items.map {
                $0.resolvingStreamURL(userID: userID)
            }
            if !tracks.isEmpty {
                return tracks
            }
        } catch let error as APIError {
            if error == .unauthorized {
                throw error
            }
        }

        let fallback = try await library(
            accessToken: accessToken,
            offset: 0,
            count: 100
        )
        return fallback.items.shuffled()
    }

    func search(
        query: String,
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Track> {
        let envelope: VKResponse<VKItems<Track>> = try await client.post(
            path: "/method/audio.search",
            form: common(accessToken).merging([
                "q": query,
                "count": String(count),
                "offset": String(offset),
                "auto_complete": "1",
                "sort": "2"
            ]) { _, new in new },
            responseType: VKResponse<VKItems<Track>>.self
        )
        let userID = await context.userID
        let resolved = VKItems(
            count: envelope.response.count,
            items: envelope.response.items.map {
                $0.resolvingStreamURL(userID: userID)
            }
        )
        return page(resolved, offset: offset, requested: count)
    }

    func playlists(
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Playlist> {
        let envelope: VKResponse<VKItems<Playlist>> = try await client.post(
            path: "/method/audio.getPlaylists",
            form: common(accessToken).merging([
                "count": String(count),
                "offset": String(offset)
            ]) { _, new in new },
            responseType: VKResponse<VKItems<Playlist>>.self
        )
        return page(envelope.response, offset: offset, requested: count)
    }

    func playlistTracks(
        _ playlist: Playlist,
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Track> {
        var parameters = [
            "owner_id": String(playlist.ownerID),
            "album_id": String(playlist.id),
            "count": String(count),
            "offset": String(offset)
        ]
        if let accessKey = playlist.accessKey {
            parameters["access_key"] = accessKey
        }
        let envelope: VKResponse<VKItems<Track>> = try await client.post(
            path: "/method/audio.get",
            form: common(accessToken).merging(parameters) { _, new in new },
            responseType: VKResponse<VKItems<Track>>.self
        )
        let userID = await context.userID
        let resolved = VKItems(
            count: envelope.response.count,
            items: envelope.response.items.map {
                $0.resolvingStreamURL(userID: userID)
            }
        )
        return page(resolved, offset: offset, requested: count)
    }

    func addToLibrary(
        _ track: Track,
        accessToken: String
    ) async throws {
        var parameters = [
            "audio_id": String(track.trackID),
            "owner_id": String(track.ownerID)
        ]
        if let accessKey = track.accessKey {
            parameters["access_key"] = accessKey
        }
        let _: VKResponse<VKIgnored> = try await client.post(
            path: "/method/audio.add",
            form: common(accessToken).merging(parameters) { _, new in new },
            responseType: VKResponse<VKIgnored>.self
        )
    }

    func removeFromLibrary(
        _ track: Track,
        accessToken: String
    ) async throws {
        let _: VKResponse<VKIgnored> = try await client.post(
            path: "/method/audio.delete",
            form: common(accessToken).merging([
                "audio_id": String(track.trackID),
                "owner_id": String(track.ownerID)
            ]) { _, new in new },
            responseType: VKResponse<VKIgnored>.self
        )
    }

    func lyrics(
        for track: Track,
        accessToken: String
    ) async throws -> Lyrics {
        if let lyricsID = track.lyricsID {
            do {
                let envelope: VKResponse<VKLyrics> = try await client.post(
                    path: "/method/audio.getLyrics",
                    form: common(accessToken).merging([
                        "lyrics_id": String(lyricsID)
                    ]) { _, new in new },
                    responseType: VKResponse<VKLyrics>.self
                )
                let text = envelope.response.text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    return Lyrics(text: text, source: "VK")
                }
            } catch let error as APIError where error == .unauthorized {
                throw error
            } catch {
                // LRCLIB below is the fallback for missing private VK lyrics.
            }
        }
        return try await lyricsService.lyrics(for: track)
    }

    func createPlaylist(
        title: String,
        description: String,
        ownerID: Int,
        accessToken: String
    ) async throws -> Playlist {
        let envelope: VKResponse<Playlist> = try await client.post(
            path: "/method/audio.createPlaylist",
            form: common(accessToken).merging([
                "owner_id": String(ownerID),
                "title": title,
                "description": description
            ]) { _, new in new },
            responseType: VKResponse<Playlist>.self
        )
        return envelope.response
    }

    func editPlaylist(
        _ playlist: Playlist,
        title: String,
        description: String,
        accessToken: String
    ) async throws {
        let _: VKResponse<VKIgnored> = try await client.post(
            path: "/method/audio.editPlaylist",
            form: common(accessToken).merging([
                "owner_id": String(playlist.ownerID),
                "playlist_id": String(playlist.id),
                "title": title,
                "description": description
            ]) { _, new in new },
            responseType: VKResponse<VKIgnored>.self
        )
    }

    func deletePlaylist(
        _ playlist: Playlist,
        accessToken: String
    ) async throws {
        let _: VKResponse<VKIgnored> = try await client.post(
            path: "/method/audio.deletePlaylist",
            form: common(accessToken).merging([
                "owner_id": String(playlist.ownerID),
                "playlist_id": String(playlist.id)
            ]) { _, new in new },
            responseType: VKResponse<VKIgnored>.self
        )
    }

    func add(
        _ track: Track,
        to playlist: Playlist,
        accessToken: String
    ) async throws {
        let _: VKResponse<VKIgnored> = try await client.post(
            path: "/method/audio.addToPlaylist",
            form: common(accessToken).merging([
                "owner_id": String(playlist.ownerID),
                "playlist_id": String(playlist.id),
                "audio_ids": track.id
            ]) { _, new in new },
            responseType: VKResponse<VKIgnored>.self
        )
    }

    func remove(
        _ track: Track,
        from playlist: Playlist,
        accessToken: String
    ) async throws {
        let _: VKResponse<VKIgnored> = try await client.post(
            path: "/method/audio.removeFromPlaylist",
            form: common(accessToken).merging([
                "owner_id": String(playlist.ownerID),
                "playlist_id": String(playlist.id),
                "audio_ids": track.id
            ]) { _, new in new },
            responseType: VKResponse<VKIgnored>.self
        )
    }

    private func common(_ token: String) -> [String: String] {
        [
            "access_token": token,
            "v": apiVersion,
            "https": "1",
            "lang": "ru"
        ]
    }

    private func page<Item: Decodable & Sendable>(
        _ response: VKItems<Item>,
        offset: Int,
        requested: Int
    ) -> MusicPage<Item> {
        let total = response.count ?? response.items.count
        let consumed = offset + response.items.count
        let hasNext = !response.items.isEmpty
            && response.items.count >= requested
            && consumed < total
        return MusicPage(
            items: response.items,
            totalCount: total,
            nextOffset: hasNext ? consumed : nil
        )
    }
}

private struct VKLyrics: Decodable, Sendable {
    let text: String
}

private struct VKIgnored: Decodable, Sendable {
    init(from decoder: Decoder) throws {}
}

private struct VKResponse<Value: Decodable & Sendable>: Decodable, Sendable {
    let response: Value
}

private struct VKItems<Item: Decodable & Sendable>: Decodable, Sendable {
    let count: Int?
    let items: [Item]
}

private actor VKMusicContext {
    private(set) var userID: Int?

    init(userID: Int?) {
        self.userID = userID
    }

    func setUserID(_ value: Int) {
        userID = value
    }
}
