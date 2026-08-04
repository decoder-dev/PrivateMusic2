import Foundation

enum AlbumTrackRequestPolicy {
    static func executeParameters(
        album: Album,
        offset: Int,
        count: Int
    ) -> [String: String] {
        var parameters = [
            "owner_id": String(album.ownerID),
            "id": String(album.albumID),
            "audio_offset": String(offset),
            "audio_count": String(count),
            "need_playlist": "1",
            "need_owner": "0"
        ]
        if let accessKey = album.accessKey?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !accessKey.isEmpty {
            parameters["access_key"] = accessKey
        }
        return parameters
    }

    static func legacyParameters(
        album: Album,
        offset: Int,
        count: Int
    ) -> [String: String] {
        var parameters = [
            "owner_id": String(album.ownerID),
            "album_id": String(album.albumID),
            "count": String(count),
            "offset": String(offset)
        ]
        if let accessKey = album.accessKey?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !accessKey.isEmpty {
            parameters["access_key"] = accessKey
        }
        return parameters
    }
}

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
        // Lossy item decode: one ad/placeholder object must not fail the
        // whole personal library page (strict VKItems<Track> did).
        let envelope: VKResponse<JSONValue> = try await client.post(
            path: "/method/audio.get",
            form: common(accessToken).merging(parameters) { _, new in new },
            responseType: VKResponse<JSONValue>.self
        )
        let items = envelope.response.libraryAudioItems.map {
            $0.resolvingStreamURL(userID: userID)
        }
        let total = envelope.response.libraryTotalCount ?? (offset + items.count)
        let consumed = offset + items.count
        let hasNext = !items.isEmpty && consumed < total
        return MusicPage(
            items: items,
            totalCount: total,
            nextOffset: hasNext ? consumed : nil
        )
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

    /// Mixes and new releases both live inside the blocks returned by
    /// `catalog.getAudio`, so this fetches it once and derives both
    /// sections from the same response instead of the two independent
    /// requests `mixes()` and the old `newReleases()` used to make.
    ///
    /// New releases remain speculative: no documented VK endpoint returns
    /// "new releases" for this client, so this scans the same catalog
    /// blocks used for mixes (and, as a fallback, a guessed releases
    /// section) for album-shaped objects. An empty array is returned
    /// rather than throwing when nothing is found — callers should hide
    /// the section instead of erroring.
    func catalogSections(accessToken: String) async throws -> CatalogSections {
        var mixes: [MusicMix] = []
        var newReleases: [Album] = []
        do {
            let envelope: VKResponse<JSONValue> = try await client.post(
                path: "/method/catalog.getAudio",
                form: common(accessToken).merging([
                    "need_blocks": "1"
                ]) { _, new in new },
                responseType: VKResponse<JSONValue>.self
            )
            mixes = envelope.response.musicMixes
            newReleases = envelope.response.releaseAlbums
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as APIError where error == .unauthorized {
            throw error
        } catch let error as APIError where error.isConnectivityFailure {
            throw error
        } catch {
            // Some VK sessions only expose these through per-section
            // fallbacks below.
        }

        if mixes.isEmpty && newReleases.isEmpty {
            async let mixesFallback = fetchMixesSection(accessToken: accessToken)
            async let releasesFallback = fetchReleasesSection(
                accessToken: accessToken
            )
            (mixes, newReleases) = try await (mixesFallback, releasesFallback)
        } else if mixes.isEmpty {
            mixes = try await fetchMixesSection(accessToken: accessToken)
        } else if newReleases.isEmpty {
            newReleases = try await fetchReleasesSection(
                accessToken: accessToken
            )
        }

        if !mixes.contains(where: { $0.id == MusicMix.common.id }) {
            mixes.insert(.common, at: 0)
        }
        return CatalogSections(mixes: mixes, newReleases: newReleases)
    }

    private func fetchMixesSection(
        accessToken: String
    ) async throws -> [MusicMix] {
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
            return envelope.response.musicMixes
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as APIError where error == .unauthorized {
            throw error
        } catch let error as APIError where error.isConnectivityFailure {
            throw error
        } catch {
            // The common mix is still a real VK stream endpoint.
            return []
        }
    }

    private func fetchReleasesSection(
        accessToken: String
    ) async throws -> [Album] {
        do {
            let envelope: VKResponse<JSONValue> = try await client.post(
                path: "/method/catalog.getSection",
                form: common(accessToken).merging([
                    "section_id": "audio_new_releases",
                    "need_blocks": "1",
                    "count": "30"
                ]) { _, new in new },
                responseType: VKResponse<JSONValue>.self
            )
            return envelope.response.releaseAlbums
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as APIError where error == .unauthorized {
            throw error
        } catch let error as APIError where error.isConnectivityFailure {
            throw error
        } catch {
            // No releases section available for this account/session.
            return []
        }
    }

    func mixTracks(
        _ mix: MusicMix,
        accessToken: String
    ) async throws -> [Track] {
        let userID = await context.userID
        // Stream mixes commonly return only three items per response even
        // when a larger count is requested, so filling a real queue needs
        // several pages. Fetching those pages concurrently instead of one
        // at a time turns what used to be up to 10 sequential round trips
        // (multi-second load, the common complaint) into roughly one
        // round trip's worth of wall-clock time. A page that fails is
        // just dropped rather than failing the whole mix, since the other
        // concurrent pages already carry usable tracks.
        let offsets = stride(from: 0, to: 1_000, by: 100)
        let pages = try await withThrowingTaskGroup(
            of: (offset: Int, tracks: [Track]).self
        ) { group -> [(offset: Int, tracks: [Track])] in
            for offset in offsets {
                group.addTask {
                    do {
                        let envelope: VKResponse<JSONValue> = try await client
                            .post(
                                path: "/method/audio.getStreamMixAudios",
                                form: common(accessToken).merging([
                                    "mix_id": mix.id,
                                    "count": "100",
                                    "offset": String(offset)
                                ]) { _, new in new },
                                responseType: VKResponse<JSONValue>.self
                            )
                        let resolved = envelope.response.tracks.map {
                            $0.resolvingStreamURL(userID: userID)
                        }
                        return (offset, resolved)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return (offset, [])
                    }
                }
            }
            var collected: [(offset: Int, tracks: [Track])] = []
            for try await page in group {
                collected.append(page)
            }
            return collected
        }
        var known = Set<String>()
        var tracks: [Track] = []
        for page in pages.sorted(by: { $0.offset < $1.offset }) {
            for track in page.tracks where known.insert(track.id).inserted {
                tracks.append(track)
            }
        }
        guard !tracks.isEmpty else { throw APIError.invalidResponse }
        return Array(tracks.prefix(30))
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
        let userID = await context.userID
        do {
            let envelope: VKResponse<JSONValue> = try await client.post(
                path: "/method/execute.getPlaylist",
                form: common(accessToken).merging(
                    AlbumTrackRequestPolicy.executeParameters(
                        album: album,
                        offset: offset,
                        count: count
                    )
                ) { _, new in new },
                responseType: VKResponse<JSONValue>.self
            )
            let rawAudioItems = envelope.response.directAudioItems
            let decodedTracks = rawAudioItems.map {
                JSONValue.array($0).tracks
            } ?? envelope.response.tracks
            let tracks = decodedTracks.map {
                $0.resolvingStreamURL(userID: userID)
            }
            if !tracks.isEmpty {
                let rawCount = rawAudioItems?.count ?? tracks.count
                let consumed = offset + rawCount
                let hasKnownRemainder = album.count > consumed
                let hasUnknownRemainder = album.count == 0
                    && rawCount >= count
                return MusicPage(
                    items: tracks,
                    totalCount: album.count > 0
                        ? album.count
                        : offset + tracks.count,
                    nextOffset: hasKnownRemainder || hasUnknownRemainder
                        ? consumed
                        : nil
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as APIError where error == .unauthorized {
            throw error
        } catch let error as APIError where error.isConnectivityFailure {
            throw error
        } catch {
            // Older sessions can reject execute.getPlaylist. The canonical
            // audio.get album query remains a compatible fallback.
        }

        let envelope: VKResponse<VKItems<Track>> = try await client.post(
            path: "/method/audio.get",
            form: common(accessToken).merging(
                AlbumTrackRequestPolicy.legacyParameters(
                    album: album,
                    offset: offset,
                    count: count
                )
            ) { _, new in new },
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

    func toggleAlbumFollow(
        _ album: Album,
        follow: Bool,
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
        // VK has no audio.unfollowPlaylist ("Unknown method passed") — the
        // real counterpart to followPlaylist for removing a followed
        // playlist/album from the library is the same deletePlaylist call
        // used for a user's own playlists.
        let path = follow
            ? "/method/audio.followPlaylist"
            : "/method/audio.deletePlaylist"
        let _: VKResponse<VKIgnored> = try await client.post(
            path: path,
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
            lyricsID: track.lyricsID,
            albumReference: track.albumReference
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
