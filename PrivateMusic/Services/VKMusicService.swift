import Foundation

struct VKMusicService: MusicService {
    private let client: APIClient
    private let apiVersion = "5.199"

    init(client: APIClient) {
        self.client = client
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

    func library(accessToken: String, offset: Int) async throws -> [Track] {
        let envelope: VKResponse<VKItems<Track>> = try await client.post(
            path: "/method/audio.get",
            form: common(accessToken).merging([
                "count": "100",
                "offset": String(offset)
            ]) { _, new in new },
            responseType: VKResponse<VKItems<Track>>.self
        )
        return envelope.response.items
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
        offset: Int
    ) async throws -> [Track] {
        let envelope: VKResponse<VKItems<Track>> = try await client.post(
            path: "/method/audio.search",
            form: common(accessToken).merging([
                "q": query,
                "count": "100",
                "offset": String(offset),
                "auto_complete": "1",
                "sort": "2"
            ]) { _, new in new },
            responseType: VKResponse<VKItems<Track>>.self
        )
        return envelope.response.items
    }

    private func common(_ token: String) -> [String: String] {
        [
            "access_token": token,
            "v": apiVersion,
            "https": "1",
            "lang": "ru"
        ]
    }
}

private struct VKResponse<Value: Decodable>: Decodable {
    let response: Value
}

private struct VKItems<Item: Decodable>: Decodable {
    let count: Int?
    let items: [Item]
}

