import Foundation

struct VKMusicService: MusicService {
    private let client: APIClient
    private let apiVersion: String

    init(client: APIClient, apiVersion: String) {
        self.client = client
        self.apiVersion = apiVersion
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
        return page(envelope.response, offset: offset, requested: count)
    }

    func recommendations(accessToken: String) async throws -> [Track] {
        let envelope: VKResponse<VKItems<Track>> = try await client.post(
            path: "/method/audio.getRecommendations",
            form: common(accessToken).merging([
                "count": "100"
            ]) { _, new in new },
            responseType: VKResponse<VKItems<Track>>.self
        )
        return envelope.response.items
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
        return page(envelope.response, offset: offset, requested: count)
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
        return page(envelope.response, offset: offset, requested: count)
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
        let _: VKResponse<Int> = try await client.post(
            path: "/method/audio.add",
            form: common(accessToken).merging(parameters) { _, new in new },
            responseType: VKResponse<Int>.self
        )
    }

    func removeFromLibrary(
        _ track: Track,
        accessToken: String
    ) async throws {
        let _: VKResponse<Int> = try await client.post(
            path: "/method/audio.delete",
            form: common(accessToken).merging([
                "audio_id": String(track.trackID),
                "owner_id": String(track.ownerID)
            ]) { _, new in new },
            responseType: VKResponse<Int>.self
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

private struct VKResponse<Value: Decodable & Sendable>: Decodable, Sendable {
    let response: Value
}

private struct VKItems<Item: Decodable & Sendable>: Decodable, Sendable {
    let count: Int?
    let items: [Item]
}
