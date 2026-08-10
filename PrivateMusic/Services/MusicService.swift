import Foundation

protocol MusicService: Sendable {
    func configure(userAgent: String?) async
    func profile(accessToken: String) async throws -> UserProfile
    func library(
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Track>
    func recommendations(
        accessToken: String,
        targetAudio: String?,
        shuffle: Bool
    ) async throws -> [Track]
    func refreshedTrack(
        _ track: Track,
        accessToken: String
    ) async throws -> Track
    func mixes(accessToken: String) async throws -> [MusicMix]
    func catalogSnapshot(accessToken: String) async throws -> VKCatalogSnapshot
    func newReleases(accessToken: String) async throws -> [Album]
    func mixTracks(
        _ mix: MusicMix,
        accessToken: String,
        startingOffset: Int,
        pages: Int
    ) async throws -> [Track]
    func search(
        query: String,
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Track>
    func searchArtists(
        query: String,
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> [VKArtist]
    func artistTracks(
        artistID: String,
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Track>
    func artistAlbums(
        artistID: String,
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Album>
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
    func resolvedAlbum(
        _ album: Album,
        accessToken: String
    ) async throws -> Album
    func toggleAlbumFollow(
        _ album: Album,
        follow: Bool,
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

extension MusicService {
    /// Personal recommendations — optional `targetAudio` seeds «микс по треку».
    func recommendations(accessToken: String) async throws -> [Track] {
        try await recommendations(
            accessToken: accessToken,
            targetAudio: nil,
            shuffle: true
        )
    }

    /// Recommendations based on a concrete track (`owner_id_audio_id`).
    func recommendations(
        seededBy track: Track,
        accessToken: String,
        shuffle: Bool = true
    ) async throws -> [Track] {
        try await recommendations(
            accessToken: accessToken,
            targetAudio: track.id,
            shuffle: shuffle
        )
    }

    /// Full mix queue fill (bootstrap + remaining pages).
    func mixTracks(
        _ mix: MusicMix,
        accessToken: String
    ) async throws -> [Track] {
        try await mixTracks(
            mix,
            accessToken: accessToken,
            startingOffset: 0,
            pages: MixTrackRequestPolicy.pageCount
        )
    }

    /// First page only — start playback before the rest of the queue arrives.
    func mixTracksBootstrap(
        _ mix: MusicMix,
        accessToken: String
    ) async throws -> [Track] {
        try await mixTracks(
            mix,
            accessToken: accessToken,
            startingOffset: 0,
            pages: MixTrackRequestPolicy.bootstrapPages
        )
    }

    /// Pages after the bootstrap, for background queue fill / continuation.
    func mixTracksContinuation(
        _ mix: MusicMix,
        accessToken: String
    ) async throws -> [Track] {
        try await mixTracksContinuation(
            mix,
            accessToken: accessToken,
            startingOffset: MixTrackRequestPolicy.bootstrapPages
                * MixTrackRequestPolicy.pageSize
        )
    }

    /// Advancing continuation page used by live radio cursors.
    func mixTracksContinuation(
        _ mix: MusicMix,
        accessToken: String,
        startingOffset: Int
    ) async throws -> [Track] {
        return try await mixTracks(
            mix,
            accessToken: accessToken,
            startingOffset: startingOffset,
            pages: MixTrackRequestPolicy.continuationPages
        )
    }
}
