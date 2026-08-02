import Foundation

struct VKMusicService: MusicService {
    private let client: APIClient
    private let apiVersion: String
    private let context: VKMusicContext
    private let lyricsService = LRCLyricsService()
    private let geniusLyricsService = GeniusLyricsService()

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
        let userID = await context.userID
        var parameters = [
            "count": String(count),
            "offset": String(offset)
        ]
        if let userID {
            parameters["owner_id"] = String(userID)
        }
        let envelope: VKResponse<VKItems<Track>> = try await client.post(
            path: "/method/audio.get",
            form: common(accessToken).merging(parameters) { _, new in new },
            responseType: VKResponse<VKItems<Track>>.self
        )
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
            let userID = await context.userID
            var parameters = [
                "count": "100",
                "shuffle": "1"
            ]
            if let userID {
                parameters["user_id"] = String(userID)
            }
            let envelope: VKResponse<VKItems<Track>> = try await client.post(
                path: "/method/audio.getRecommendations",
                form: common(accessToken).merging(parameters) { _, new in new },
                responseType: VKResponse<VKItems<Track>>.self
            )
            let tracks = envelope.response.items.map {
                $0.resolvingStreamURL(userID: userID)
            }
            if !tracks.isEmpty {
                return tracks
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as APIError where error == .unauthorized {
            throw error
        } catch let error as APIError where error.isConnectivityFailure {
            throw error
        }

        // Some valid VK sessions do not expose getRecommendations, while the
        // personal stream endpoint remains available for the same account.
        return try await mixTracks(.common, accessToken: accessToken)
    }

    func refreshedTrack(
        _ track: Track,
        accessToken: String
    ) async throws -> Track {
        var audioID = track.id
        if let accessKey = track.accessKey, !accessKey.isEmpty {
            audioID += "_\(accessKey)"
        }
        let envelope: VKResponse<[Track]> = try await client.post(
            path: "/method/audio.getById",
            form: common(accessToken).merging([
                "audios": audioID
            ]) { _, new in new },
            responseType: VKResponse<[Track]>.self
        )
        let userID = await context.userID
        guard let first = envelope.response.first else {
            throw APIError.invalidResponse
        }
        let refreshed = first.resolvingStreamURL(userID: userID)
        guard refreshed.streamURL != nil else {
            throw APIError.invalidResponse
        }
        return refreshed
    }

    func mixes(accessToken: String) async throws -> [MusicMix] {
        var discovered: [MusicMix] = []
        do {
            let envelope: VKResponse<JSONValue> = try await client.post(
                path: "/method/catalog.getAudio",
                form: common(accessToken).merging([
                    "need_blocks": "1"
                ]) { _, new in new },
                responseType: VKResponse<JSONValue>.self
            )
            discovered = envelope.response.musicMixes
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as APIError where error == .unauthorized {
            throw error
        } catch let error as APIError where error.isConnectivityFailure {
            throw error
        } catch {
            // Some VK sessions only expose stream mixes through the section.
        }

        if discovered.isEmpty {
            do {
                let envelope: VKResponse<JSONValue> = try await client.post(
                    path: "/method/catalog.getSection",
                    form: common(accessToken).merging([
                        "section_id": "audio_stream_mixes",
                        "need_blocks": "1",
                        "count": "30"
                    ]) { _, new in new },
                    responseType: VKResponse<JSONValue>.self
                )
                discovered = envelope.response.musicMixes
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as APIError where error == .unauthorized {
                throw error
            } catch let error as APIError where error.isConnectivityFailure {
                throw error
            } catch {
                // The common mix is still a real VK stream endpoint.
            }
        }

        if !discovered.contains(where: { $0.id == MusicMix.common.id }) {
            discovered.insert(.common, at: 0)
        }
        return discovered
    }

    func mixTracks(
        _ mix: MusicMix,
        accessToken: String
    ) async throws -> [Track] {
        let userID = await context.userID
        var tracks: [Track] = []
        var known = Set<String>()
        var offset = 0
        var duplicateOnlyPages = 0
        // Stream mixes commonly return only three items per response even
        // when a larger count is requested. Fill the initial queue from
        // several pages so playback does not stop after that first triplet.
        for _ in 0..<10 {
            try Task.checkCancellation()
            let envelope: VKResponse<JSONValue> = try await client.post(
                path: "/method/audio.getStreamMixAudios",
                form: common(accessToken).merging([
                    "mix_id": mix.id,
                    "count": "100",
                    "offset": String(offset)
                ]) { _, new in new },
                responseType: VKResponse<JSONValue>.self
            )
            let rawTracks = envelope.response.tracks
            guard !rawTracks.isEmpty else { break }
            offset += rawTracks.count
            let additions = rawTracks
                .map { $0.resolvingStreamURL(userID: userID) }
                .filter { known.insert($0.id).inserted }
            tracks.append(contentsOf: additions)
            duplicateOnlyPages = additions.isEmpty
                ? duplicateOnlyPages + 1
                : 0
            if duplicateOnlyPages >= 2 { break }
            if tracks.count >= 30 { break }
        }
        guard !tracks.isEmpty else { throw APIError.invalidResponse }
        return tracks
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

    func searchAlbums(
        query: String,
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Album> {
        let envelope: VKResponse<VKItems<Album>> = try await client.post(
            path: "/method/audio.searchAlbums",
            form: common(accessToken).merging([
                "q": query,
                "count": String(count),
                "offset": String(offset)
            ]) { _, new in new },
            responseType: VKResponse<VKItems<Album>>.self
        )
        return page(envelope.response, offset: offset, requested: count)
    }

    func likedAlbums(
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Album> {
        let userID = await context.userID
        var parameters = [
            "count": String(count),
            "offset": String(offset),
            "filters": "followed,albums"
        ]
        if let userID {
            parameters["owner_id"] = String(userID)
        }
        let envelope: VKResponse<VKItems<Album>> = try await client.post(
            path: "/method/audio.getPlaylists",
            form: common(accessToken).merging(parameters) { _, new in new },
            responseType: VKResponse<VKItems<Album>>.self
        )
        return page(envelope.response, offset: offset, requested: count)
    }

    func albumTracks(
        _ album: Album,
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Track> {
        var parameters = [
            "owner_id": String(album.ownerID),
            "album_id": String(album.albumID),
            "count": String(count),
            "offset": String(offset)
        ]
        if let accessKey = album.accessKey {
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

    func toggleAlbumFollow(
        _ album: Album,
        accessToken: String
    ) async throws {
        var parameters = [
            "owner_id": String(album.ownerID),
            "playlist_id": String(album.albumID)
        ]
        if let followHash = album.followHash {
            parameters["hash"] = followHash
        }
        if let accessKey = album.accessKey {
            parameters["access_key"] = accessKey
        }
        let _: VKResponse<VKIgnored> = try await client.post(
            path: "/method/audio.followPlaylist",
            form: common(accessToken).merging(parameters) { _, new in new },
            retryPolicy: .never,
            responseType: VKResponse<VKIgnored>.self
        )
    }

    func playlists(
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Playlist> {
        let userID = await context.userID
        var parameters = [
            "count": String(count),
            "offset": String(offset)
        ]
        if let userID {
            parameters["owner_id"] = String(userID)
        }
        let envelope: VKResponse<VKItems<Playlist>> = try await client.post(
            path: "/method/audio.getPlaylists",
            form: common(accessToken).merging(parameters) { _, new in new },
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
    ) async throws -> Track {
        var parameters = [
            "audio_id": String(track.trackID),
            "owner_id": String(track.ownerID)
        ]
        if let accessKey = track.accessKey {
            parameters["access_key"] = accessKey
        }
        let envelope: VKResponse<VKAudioAddResult> = try await client.post(
            path: "/method/audio.add",
            form: common(accessToken).merging(parameters) { _, new in new },
            retryPolicy: .never,
            responseType: VKResponse<VKAudioAddResult>.self
        )
        let userID = await context.userID
        return Track(
            trackID: envelope.response.id,
            ownerID: userID ?? track.ownerID,
            title: track.title,
            artist: track.artist,
            albumTitle: track.albumTitle,
            duration: track.duration,
            streamURL: track.streamURL,
            artworkURL: track.artworkURL,
            accessKey: nil,
            lyricsID: track.lyricsID
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
            retryPolicy: .never,
            responseType: VKResponse<VKIgnored>.self
        )
    }

    func lyrics(
        for track: Track,
        accessToken: String
    ) async throws -> Lyrics {
        do {
            return try await geniusLyricsService.lyrics(for: track)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Genius can reject automated requests in some regions.
        }
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
            } catch is CancellationError {
                throw CancellationError()
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
            retryPolicy: .never,
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
            retryPolicy: .never,
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
            retryPolicy: .never,
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
            retryPolicy: .never,
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
            retryPolicy: .never,
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

    func page<Item: Decodable & Sendable>(
        _ response: VKItems<Item>,
        offset: Int,
        requested: Int
    ) -> MusicPage<Item> {
        let total = response.count ?? response.items.count
        let consumed = offset + response.items.count
        let hasNext = !response.items.isEmpty
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

private struct VKAudioAddResult: Decodable, Sendable {
    let id: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            id = value
            return
        }
        if let value = try? container.decode(String.self),
           let parsed = Int(value) {
            id = parsed
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "VK audio.add returned no audio identifier."
        )
    }
}

private struct VKIgnored: Decodable, Sendable {
    init(from decoder: Decoder) throws {}
}

private struct VKResponse<Value: Decodable & Sendable>: Decodable, Sendable {
    let response: Value
}

struct VKItems<Item: Decodable & Sendable>: Decodable, Sendable {
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
