import Foundation

protocol MusicService: Sendable {
    func profile(accessToken: String) async throws -> UserProfile
    func library(accessToken: String, offset: Int) async throws -> [Track]
    func recommendations(accessToken: String) async throws -> [Track]
    func search(
        query: String,
        accessToken: String,
        offset: Int
    ) async throws -> [Track]
}

