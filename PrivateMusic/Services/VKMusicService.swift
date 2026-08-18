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
        let userID = try await resolvedUserID(accessToken: accessToken)
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
        // Advance by the raw entry count: skipping an ad object must not
        // make the next request replay this window.
        let received = max(envelope.response.libraryItemCount, items.count)
        let total = envelope.response.libraryTotalCount ?? (offset + received)
        let consumed = offset + received
        let hasNext = received > 0 && consumed < total
        return MusicPage(
            items: items,
            totalCount: total,
            nextOffset: hasNext ? consumed : nil
        )
    }

    func recommendations(
        accessToken: String,
        targetAudio: String?,
        shuffle: Bool
    ) async throws -> [Track] {
        do {
            let userID = try await resolvedUserID(accessToken: accessToken)
            var parameters = [
                "count": "100",
                "shuffle": shuffle ? "1" : "0"
            ]
            if let userID {
                parameters["user_id"] = String(userID)
            }
            // Official «микс по треку» / radio-from-seed entry point.
            if let targetAudio,
               !targetAudio.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty {
                parameters["target_audio"] = targetAudio
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
        // Seeded radio cannot fall back to the personal stream meaningfully.
        if targetAudio != nil {
            throw APIError.invalidResponse
        }
        return try await mixTracks(.common, accessToken: accessToken)
    }

    /// Fresh `audio.getById` URL. Clients such as LavaSrc do this immediately
    /// before play; we do it when the live URL is still HLS after the local
    /// m3u8→mp3 rewrite. No board-comment rip, no unofficial API proxy.
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
            retryPolicy: .playbackRecovery,
            responseType: VKResponse<[Track]>.self
        )
        let userID = try await resolvedUserID(accessToken: accessToken)
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
        let snapshot = try await catalogSnapshot(accessToken: accessToken)
        return snapshot.mixes
    }

    /// Loads mixes and new-release albums from real catalog section ids
    /// returned by `catalog.getAudio`, then hydrates matching official
    /// sections via `catalog.getSection` in parallel.
    func catalogSnapshot(
        accessToken: String
    ) async throws -> VKCatalogSnapshot {
        var mixes: [MusicMix] = []
        var releases: [Album] = []
        var sections: [CatalogSectionRef] = []

        do {
            let envelope: VKResponse<JSONValue> = try await client.post(
                path: "/method/catalog.getAudio",
                form: common(accessToken).merging([
                    "need_blocks": "1"
                ]) { _, new in new },
                responseType: VKResponse<JSONValue>.self
            )
            mixes = envelope.response.musicMixes
            releases = envelope.response.releaseAlbums
            sections = envelope.response.catalogSections
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as APIError where error == .unauthorized {
            throw error
        } catch let error as APIError where error.isConnectivityFailure {
            throw error
        } catch {
            // Section hydration below may still recover usable content.
        }

        let mixSections = Array(
            sections
                .filter(CatalogSectionPolicy.looksLikeMixSection)
                .prefix(CatalogSectionPolicy.hydrationLimit)
        )
        let releaseSections = Array(
            sections
                .filter(CatalogSectionPolicy.looksLikeReleasesSection)
                .prefix(CatalogSectionPolicy.hydrationLimit)
        )

        // Always hydrate official mix sections (not only when the root
        // catalog returned ≤1 mix). Thin root payloads with 2–3 mixes still
        // miss most of the VK mixes page.
        if !mixSections.isEmpty {
            let hydrated = await hydrateSections(
                mixSections,
                accessToken: accessToken
            ) { payload, section in
                payload.musicMixes.map { $0.withSectionTitle(section.title) }
            }
            mixes = mergingMixes(mixes, hydrated)
        }

        if releases.isEmpty, !releaseSections.isEmpty {
            let hydrated = await hydrateSections(
                releaseSections,
                accessToken: accessToken
            ) { payload, _ in
                payload.releaseAlbums
            }
            releases = mergingAlbums(releases, hydrated)
        }

        if !mixes.contains(where: { $0.id == MusicMix.common.id }) {
            mixes.insert(.common, at: 0)
        }

        return VKCatalogSnapshot(
            mixes: mixes,
            newReleases: releases,
            sections: sections
        )
    }

    func newReleases(accessToken: String) async throws -> [Album] {
        let snapshot = try await catalogSnapshot(accessToken: accessToken)
        return snapshot.newReleases
    }

    func mixTracks(
        _ mix: MusicMix,
        accessToken: String,
        startingOffset: Int,
        pages: Int
    ) async throws -> [Track] {
        let userID = try await resolvedUserID(accessToken: accessToken)
        let pageSize = MixTrackRequestPolicy.pageSize
        let pageCount = max(pages, 1)
        let baseOffset = max(startingOffset, 0)
        let offsets = (0..<pageCount).map { baseOffset + $0 * pageSize }
        let collectedPages = try await withThrowingTaskGroup(
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
                                    "count": String(pageSize),
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
        for page in collectedPages.sorted(by: { $0.offset < $1.offset }) {
            for track in page.tracks where known.insert(track.id).inserted {
                tracks.append(track)
            }
        }
        guard !tracks.isEmpty else { throw APIError.invalidResponse }
        return Array(tracks.prefix(MixTrackRequestPolicy.queueLimit))
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
        let userID = try await resolvedUserID(accessToken: accessToken)
        let resolved = VKItems(
            count: envelope.response.count,
            items: envelope.response.items.map {
                $0.resolvingStreamURL(userID: userID)
            }
        )
        return page(resolved, offset: offset, requested: count)
    }

    func searchArtists(
        query: String,
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> [VKArtist] {
        let envelope: VKResponse<JSONValue> = try await client.post(
            path: "/method/audio.searchArtists",
            form: common(accessToken).merging([
                "q": query,
                "count": String(count),
                "offset": String(offset)
            ]) { _, new in new },
            responseType: VKResponse<JSONValue>.self
        )
        let artists = envelope.response.artists
        if !artists.isEmpty {
            return artists
        }
        // Kate sometimes returns `{count, items:[artist…]}` which the
        // recursive collector already walks via `artists`.
        return []
    }

    func artistTracks(
        artistID: String,
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Track> {
        let userID = try await resolvedUserID(accessToken: accessToken)
        do {
            let envelope: VKResponse<VKItems<Track>> = try await client.post(
                path: "/method/audio.getAudiosByArtist",
                form: common(accessToken).merging([
                    "artist_id": artistID,
                    "count": String(count),
                    "offset": String(offset)
                ]) { _, new in new },
                responseType: VKResponse<VKItems<Track>>.self
            )
            let resolved = VKItems(
                count: envelope.response.count,
                items: envelope.response.items.map {
                    $0.resolvingStreamURL(userID: userID)
                }
            )
            if !resolved.items.isEmpty {
                return page(resolved, offset: offset, requested: count)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as APIError where error == .unauthorized {
            throw error
        } catch let error as APIError where error.isConnectivityFailure {
            throw error
        } catch {
            // Fall through to catalog artist page.
        }

        let envelope: VKResponse<JSONValue> = try await client.post(
            path: "/method/catalog.getAudioArtist",
            form: common(accessToken).merging([
                "artist_id": artistID,
                "need_blocks": "1"
            ]) { _, new in new },
            responseType: VKResponse<JSONValue>.self
        )
        let tracks = envelope.response.tracks.map {
            $0.resolvingStreamURL(userID: userID)
        }
        let sliced = Array(tracks.dropFirst(offset).prefix(count))
        let consumed = offset + sliced.count
        return MusicPage(
            items: sliced,
            totalCount: tracks.count,
            nextOffset: consumed < tracks.count ? consumed : nil
        )
    }

    func artistAlbums(
        artistID: String,
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Album> {
        var listItems: [Album] = []
        do {
            let envelope: VKResponse<VKItems<Album>> = try await client.post(
                path: "/method/audio.getAlbumsByArtist",
                form: common(accessToken).merging([
                    "artist_id": artistID,
                    "count": String(count),
                    "offset": String(offset)
                ]) { _, new in new },
                responseType: VKResponse<VKItems<Album>>.self
            )
            listItems = envelope.response.items
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as APIError where error == .unauthorized {
            throw error
        } catch let error as APIError where error.isConnectivityFailure {
            throw error
        } catch {
            // Fall through to catalog artist page albums.
        }

        let catalogAlbums: [Album]
        do {
            let envelope: VKResponse<JSONValue> = try await client.post(
                path: "/method/catalog.getAudioArtist",
                form: common(accessToken).merging([
                    "artist_id": artistID,
                    "need_blocks": "1"
                ]) { _, new in new },
                responseType: VKResponse<JSONValue>.self
            )
            catalogAlbums = envelope.response.releaseAlbums
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as APIError where error == .unauthorized {
            throw error
        } catch let error as APIError where error.isConnectivityFailure {
            throw error
        } catch {
            catalogAlbums = []
        }

        let merged: [Album]
        if listItems.isEmpty {
            merged = catalogAlbums
        } else if ArtistAlbumShelfPolicy.shouldPreferCatalog(over: listItems) {
            // Sparse getAlbumsByArtist stubs used to short-circuit the
            // catalog path and paint every card as «0 треков» with no art.
            merged = catalogAlbums.isEmpty ? listItems : catalogAlbums
        } else {
            merged = ArtistAlbumShelfPolicy.merging(
                list: listItems,
                catalog: catalogAlbums
            )
        }

        let sliced = Array(merged.dropFirst(offset).prefix(count))
        let consumed = offset + sliced.count
        return MusicPage(
            items: sliced,
            totalCount: merged.count,
            nextOffset: consumed < merged.count ? consumed : nil
        )
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
        let userID = try await resolvedUserID(accessToken: accessToken)
        // `filters` unions the categories it names, so the long-standing
        // `followed,albums` asked for every playlist saved from another
        // person on top of the releases — and the playlist shelf subtracts
        // whatever this list reports.
        var parameters = [
            "count": String(count),
            "offset": String(offset),
            "filters": LibraryPlaylistPagePolicy.albumShelfFilters
        ]
        if let userID {
            parameters["owner_id"] = String(userID)
        }
        // Lossy item decode, like the playlist list, and each entry is still
        // classified: a playlist VK leaves in this list must not reach the
        // ids the playlist shelf subtracts.
        let envelope: VKResponse<JSONValue> = try await client.post(
            path: "/method/audio.getPlaylists",
            form: common(accessToken).merging(parameters) { _, new in new },
            responseType: VKResponse<JSONValue>.self
        )
        return followedAlbumPage(
            envelope.response,
            offset: offset,
            requested: count
        )
    }

    func albumTracks(
        _ album: Album,
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Track> {
        let effective = try await resolvedAlbum(
            album,
            accessToken: accessToken
        )
        var lastError: Error?
        do {
            let page = try await fetchAlbumTracks(
                effective,
                accessToken: accessToken,
                offset: offset,
                count: count
            )
            if !page.items.isEmpty {
                return page
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as APIError where error == .unauthorized {
            throw error
        } catch let error as APIError where error.isConnectivityFailure {
            throw error
        } catch {
            lastError = error
            if AlbumAccessPolicy.isAudioAccessDenied(error),
               let recovered = try? await resolveAlbumAccessKey(
                album,
                accessToken: accessToken,
                forceSearch: true
               ),
               AlbumAccessPolicy.usableAccessKey(from: recovered)
                != AlbumAccessPolicy.usableAccessKey(from: effective),
               let page = try? await fetchAlbumTracks(
                recovered,
                accessToken: accessToken,
                offset: offset,
                count: count
               ),
               !page.items.isEmpty {
                return page
            }
        }

        // Playlist endpoints stay denied / empty for some Kate sessions even
        // with a key. Reconstruct the album from public audio.search hits.
        if let fallback = try? await albumTracksViaSearch(
            album,
            accessToken: accessToken,
            offset: offset,
            count: count
        ), !fallback.items.isEmpty {
            return fallback
        }

        if let lastError,
           AlbumAccessPolicy.isAudioAccessDenied(lastError) {
            throw Self.albumAccessDeniedError(from: lastError)
        }
        if let lastError {
            throw lastError
        }
        throw APIError.invalidResponse
    }

    /// Ensures community albums carry a usable `access_key` before track /
    /// follow calls. No-op when the key is already present or owner is a user.
    func resolvedAlbum(
        _ album: Album,
        accessToken: String
    ) async throws -> Album {
        if !AlbumAccessPolicy.needsAccessKeyResolution(album) {
            return album
        }
        return try await resolveAlbumAccessKey(
            album,
            accessToken: accessToken,
            forceSearch: false
        ) ?? album
    }

    private func fetchAlbumTracks(
        _ album: Album,
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Track> {
        let userID = try await resolvedUserID(accessToken: accessToken)
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
        } catch let error where AlbumAccessPolicy.isAudioAccessDenied(error) {
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

    private func resolveAlbumAccessKey(
        _ album: Album,
        accessToken: String,
        forceSearch: Bool
    ) async throws -> Album? {
        if !forceSearch,
           AlbumAccessPolicy.hasUsableAccessKey(album) {
            return album
        }

        // Prefer getPlaylistById when we already have a key or a user-owned
        // playlist; for missing community keys, search usually returns one.
        if AlbumAccessPolicy.hasUsableAccessKey(album)
            || album.ownerID > 0 {
            if let detailed = try? await playlistByID(
                album,
                accessToken: accessToken
            ) {
                return album.mergingAccessMetadata(from: detailed)
            }
        }

        var candidates: [Album] = []
        var seen = Set<String>()
        for query in AlbumAccessPolicy.searchQueries(for: album) {
            let page = try await searchAlbums(
                query: query,
                accessToken: accessToken,
                offset: 0,
                count: 30
            )
            for item in page.items where seen.insert(item.compositeID).inserted {
                candidates.append(item)
            }
        }
        guard let match = AlbumAccessPolicy.preferredMatch(
            in: candidates,
            for: album
        ) else {
            return nil
        }
        return album.mergingAccessMetadata(from: match)
    }

    /// When playlist APIs deny access, rebuild a usable track list from
    /// public `audio.search` results that belong to the same album.
    private func albumTracksViaSearch(
        _ album: Album,
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Track> {
        var collected: [Track] = []
        var known = Set<String>()

        func append(
            _ tracks: [Track],
            softArtistMatch: Bool
        ) {
            for track in tracks {
                let matches = AlbumAccessPolicy.trackBelongs(track, to: album)
                    || (softArtistMatch
                        && AlbumAccessPolicy.artistMatches(track, album: album))
                guard matches, known.insert(track.id).inserted else {
                    continue
                }
                collected.append(track)
            }
        }

        for query in AlbumAccessPolicy.searchQueries(for: album) {
            let page = try await search(
                query: query,
                accessToken: accessToken,
                offset: 0,
                count: 100
            )
            // Kate search often omits album_title. For queries that already
            // include the album name, artist match is enough.
            let queryHasTitle = Album.isUsableTitle(album.title)
                && query.localizedCaseInsensitiveContains(album.title)
            append(page.items, softArtistMatch: queryHasTitle)
            if collected.count >= max(count + offset, 40) {
                break
            }
        }

        // If the resolved search album has a key, try playlist fetch on that
        // locator before giving up on structured album order.
        if collected.count < 8,
           AlbumAccessPolicy.hasUsableAccessKey(album),
           let page = try? await fetchAlbumTracks(
            album,
            accessToken: accessToken,
            offset: 0,
            count: max(count + offset, 100)
           ) {
            append(page.items, softArtistMatch: false)
        }

        // Artist catalog is a second public source when title search is thin.
        if collected.count < 8,
           let artistName = album.artists.first,
           let artist = try? await searchArtists(
            query: artistName,
            accessToken: accessToken,
            offset: 0,
            count: 5
           ).first,
           let artistPage = try? await artistTracks(
            artistID: artist.id,
            accessToken: accessToken,
            offset: 0,
            count: 100
           ) {
            append(artistPage.items, softArtistMatch: false)
            // Last resort: keep artist tracks whose album title is missing
            // but which appeared under a title-bearing search above already
            // handled; here only strict belongs applies.
        }

        // Absolute last resort — artist-matched search hits for the album
        // title alone, even when album_title is absent on every item.
        if collected.isEmpty,
           Album.isUsableTitle(album.title) {
            let page = try await search(
                query: album.title,
                accessToken: accessToken,
                offset: 0,
                count: 100
            )
            append(page.items, softArtistMatch: true)
            if collected.isEmpty {
                // Still nothing filtered — return top search hits so the
                // screen is not empty for a known album title query.
                for track in page.items
                where known.insert(track.id).inserted {
                    collected.append(track)
                    if collected.count >= count { break }
                }
            }
        }

        guard !collected.isEmpty else {
            throw APIError.invalidResponse
        }
        let sliced = Array(collected.dropFirst(offset).prefix(count))
        let consumed = offset + sliced.count
        return MusicPage(
            items: sliced,
            totalCount: collected.count,
            nextOffset: consumed < collected.count ? consumed : nil
        )
    }

    private func playlistByID(
        _ album: Album,
        accessToken: String
    ) async throws -> Album {
        var parameters = [
            "owner_id": String(album.ownerID),
            "playlist_id": String(album.albumID)
        ]
        if let accessKey = AlbumAccessPolicy.usableAccessKey(from: album) {
            parameters["access_key"] = accessKey
        }
        let envelope: VKResponse<Album> = try await client.post(
            path: "/method/audio.getPlaylistById",
            form: common(accessToken).merging(parameters) { _, new in new },
            responseType: VKResponse<Album>.self
        )
        return envelope.response
    }

    private static func albumAccessDeniedError(from error: Error) -> APIError {
        if let apiError = error as? APIError,
           case let .server(code, _) = apiError {
            return .server(
                code: code,
                message: L10n.text(
                    "could_not_load_this_album_s_tracks_try_again_or_find_it_in_search"
                )
            )
        }
        return .server(
            code: 15,
            message: L10n.text(
                "could_not_load_this_album_s_tracks_try_again_or_find_it_in_search"
            )
        )
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
        let path = AlbumFollowPolicy.methodPath(follow: follow)
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
        let userID = try await resolvedUserID(accessToken: accessToken)
        // No `filters`: the narrowed `owned,followed` list dropped playlists
        // that VK only reports under the default `all` filter. Followed
        // albums come back in that list too — they are excluded per item
        // below and stay on the Albums shelf via `likedAlbums`.
        var parameters = [
            "count": String(count),
            "offset": String(offset)
        ]
        if let userID {
            parameters["owner_id"] = String(userID)
        }
        // Lossy item decode: one undecodable playlist / ad object must not
        // fail the whole page, the way the strict page decode did.
        let envelope: VKResponse<JSONValue> = try await client.post(
            path: "/method/audio.getPlaylists",
            form: common(accessToken).merging(parameters) { _, new in new },
            responseType: VKResponse<JSONValue>.self
        )
        return playlistPage(
            envelope.response,
            offset: offset,
            requested: count
        )
    }

    func playlistTracks(
        _ playlist: Playlist,
        accessToken: String,
        offset: Int,
        count: Int
    ) async throws -> MusicPage<Track> {
        var parameters = [
            "owner_id": String(playlist.ownerID),
            "album_id": String(playlist.playlistID),
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
        let userID = try await resolvedUserID(accessToken: accessToken)
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
        let userID = try await resolvedUserID(accessToken: accessToken)
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
            albumReference: track.albumReference,
            isHQ: track.isHQ
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
                "playlist_id": String(playlist.playlistID),
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
                "playlist_id": String(playlist.playlistID)
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
                "playlist_id": String(playlist.playlistID),
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
                "playlist_id": String(playlist.playlistID),
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

    /// Ensures stream URL unmasking has a user id (from context or users.get).
    private func resolvedUserID(accessToken: String) async throws -> Int? {
        if let userID = await context.userID {
            return userID
        }
        do {
            let profile = try await profile(accessToken: accessToken)
            return profile.id
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as APIError where error == .unauthorized {
            throw error
        } catch {
            return await context.userID
        }
    }

    private func catalogSectionPayload(
        sectionID: String,
        accessToken: String
    ) async throws -> JSONValue {
        let envelope: VKResponse<JSONValue> = try await client.post(
            path: "/method/catalog.getSection",
            form: common(accessToken).merging([
                "section_id": sectionID
            ]) { _, new in new },
            responseType: VKResponse<JSONValue>.self
        )
        return envelope.response
    }

    /// Bounded parallel `catalog.getSection` hydration. Failures for one
    /// section do not abort the rest.
    private func hydrateSections<Item>(
        _ sections: [CatalogSectionRef],
        accessToken: String,
        extract: @escaping @Sendable (JSONValue, CatalogSectionRef) -> [Item]
    ) async -> [Item] where Item: Sendable {
        await withTaskGroup(of: [Item].self) { group in
            for section in sections {
                group.addTask {
                    do {
                        let payload = try await catalogSectionPayload(
                            sectionID: section.id,
                            accessToken: accessToken
                        )
                        return extract(payload, section)
                    } catch {
                        return []
                    }
                }
            }
            var collected: [Item] = []
            for await items in group {
                collected.append(contentsOf: items)
            }
            return collected
        }
    }

    private func mergingMixes(
        _ lhs: [MusicMix],
        _ rhs: [MusicMix]
    ) -> [MusicMix] {
        var known = Set(lhs.map(\.id))
        var result = lhs
        for mix in rhs where known.insert(mix.id).inserted {
            result.append(mix)
        }
        return result
    }

    private func mergingAlbums(
        _ lhs: [Album],
        _ rhs: [Album]
    ) -> [Album] {
        var known = Set(lhs.map(\.id))
        var result = lhs
        for album in rhs where known.insert(album.id).inserted {
            result.append(album)
        }
        return result
    }

    /// Assembles an `audio.getPlaylists` page from a lossily decoded
    /// payload. The offset advances by the number of raw entries VK
    /// returned rather than by the number that survived decoding and the
    /// album filter, so a page full of followed albums still moves on
    /// instead of re-requesting the same window.
    func playlistPage(
        _ value: JSONValue,
        offset: Int,
        requested: Int = LibraryPlaylistPagePolicy.pageSize
    ) -> MusicPage<Playlist> {
        let items = value.libraryPlaylistItems
        let received = value.libraryItemCount
        let total = value.libraryTotalCount ?? (offset + received)
        return MusicPage(
            items: items,
            totalCount: max(total, offset + received),
            nextOffset: LibraryPlaylistPagePolicy.nextOffset(
                after: offset,
                received: received,
                requested: requested,
                total: total
            )
        )
    }

    /// Assembles the Albums shelf page from the same `audio.getPlaylists`
    /// payload shape, dropping the saved playlists the `followed` filter
    /// hands back next to the releases. The offset advances by the raw entry
    /// count for the same reason as `playlistPage`.
    func followedAlbumPage(
        _ value: JSONValue,
        offset: Int,
        requested: Int = LibraryPlaylistPagePolicy.pageSize
    ) -> MusicPage<Album> {
        let items = value.libraryFollowedAlbumItems
        let received = value.libraryItemCount
        let total = value.libraryTotalCount ?? (offset + received)
        return MusicPage(
            items: items,
            totalCount: max(total, offset + received),
            nextOffset: LibraryPlaylistPagePolicy.nextOffset(
                after: offset,
                received: received,
                requested: requested,
                total: total
            )
        )
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
