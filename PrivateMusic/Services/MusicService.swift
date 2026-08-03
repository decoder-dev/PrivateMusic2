import Foundation

protocol MusicService: Sendable {
    func configure(userAgent: String?) async
    func profile(accessToken: String) async throws -> UserProfile
    func library(
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Track>
    func recommendations(accessToken: String) async throws -> [Track]
    func refreshedTrack(
        _ track: Track,
        accessToken: String
    ) async throws -> Track
    func mixes(accessToken: String) async throws -> [MusicMix]
    func mixTracks(
        _ mix: MusicMix,
        accessToken: String
    ) async throws -> [Track]
    func search(
        query: String,
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Track>
    func searchAlbums(
        query: String,
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Album>
    func likedAlbums(
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Album>
    func albumTracks(
        _ album: Album,
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Track>
    func toggleAlbumFollow(
        _ album: Album,
        accessToken: String
    ) async throws
    func playlists(
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Playlist>
    func playlistTracks(
        _ playlist: Playlist,
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Track>
    func addToLibrary(
        _ track: Track,
        accessToken: String
    ) async throws -> Track
    func removeFromLibrary(
        _ track: Track,
        accessToken: String
    ) async throws
    func lyrics(
        for track: Track,
        accessToken: String
    ) async throws -> Lyrics
    func createPlaylist(
        title: String,
        description: String,
        ownerID: Int,
        accessToken: String
    ) async throws -> Playlist
    func editPlaylist(
        _ playlist: Playlist,
        title: String,
        description: String,
        accessToken: String
    ) async throws
    func deletePlaylist(
        _ playlist: Playlist,
        accessToken: String
    ) async throws
    func add(
        _ track: Track,
        to playlist: Playlist,
        accessToken: String
    ) async throws
    func remove(
        _ track: Track,
        from playlist: Playlist,
        accessToken: String
    ) async throws
}
