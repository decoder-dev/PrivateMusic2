import Foundation

/// All writes are single-attempt: an uncertain response must not duplicate an upload.
extension VKMusicService {
    func playlistDetails(_ playlist: Playlist, accessToken: String) async throws -> Playlist {
        var form = common(accessToken)
        form["owner_id"] = String(playlist.ownerID)
        form["playlist_id"] = String(playlist.playlistID)
        if let key = playlist.accessKey { form["access_key"] = key }
        let result: VKResponse<Playlist> = try await client.post(path: "/method/audio.getPlaylistById",
            form: form, responseType: VKResponse<Playlist>.self)
        return result.response
    }

    func createPlaylist(title: String, description: String, ownerID: Int, hidden: Bool, accessToken: String) async throws -> Playlist {
        let result: VKResponse<Playlist> = try await client.post(path: "/method/audio.createPlaylist",
            form: common(accessToken).merging(["owner_id": String(ownerID), "title": title,
                "description": description, "no_discover": hidden ? "1" : "0"]) { _, new in new },
            retryPolicy: .never, responseType: VKResponse<Playlist>.self)
        return result.response
    }

    func friends(accessToken: String, offset: Int, count: Int) async throws -> MusicPage<UserProfile> {
        let result: VKResponse<VKItems<UserProfile>> = try await client.post(
            path: "/method/friends.get",
            form: common(accessToken).merging([
                "fields": "photo_200", "order": "name",
                "offset": String(offset), "count": String(count)
            ]) { _, new in new }, responseType: VKResponse<VKItems<UserProfile>>.self)
        let page = result.response
        return MusicPage(items: page.items, totalCount: page.count ?? offset + page.items.count,
            nextOffset: VKLibraryPagePolicy.next(offset: offset, received: page.items.count, total: page.count ?? offset + page.items.count))
    }

    func friendTracks(ownerID: Int, accessToken: String, offset: Int, count: Int) async throws -> MusicPage<Track> {
        let userID = try await resolvedUserID(accessToken: accessToken)
        let result: VKResponse<JSONValue> = try await client.post(
            path: "/method/audio.get", form: common(accessToken).merging([
                "owner_id": String(ownerID), "offset": String(offset), "count": String(count)
            ]) { _, new in new }, responseType: VKResponse<JSONValue>.self)
        let items = result.response.libraryAudioItems.map { $0.resolvingStreamURL(userID: userID) }
        let received = max(items.count, result.response.libraryItemCount)
        let total = result.response.libraryTotalCount ?? offset + received
        return MusicPage(items: items, totalCount: total,
            nextOffset: VKLibraryPagePolicy.next(offset: offset, received: received, total: total))
    }

    func friendPlaylists(ownerID: Int, accessToken: String, offset: Int, count: Int) async throws -> MusicPage<Playlist> {
        let result: VKResponse<JSONValue> = try await client.post(
            path: "/method/audio.getPlaylists", form: common(accessToken).merging([
                "owner_id": String(ownerID), "offset": String(offset), "count": String(count)
            ]) { _, new in new }, responseType: VKResponse<JSONValue>.self)
        return playlistPage(result.response, offset: offset, requested: count)
    }

    func setPlaylistHidden(_ playlist: Playlist, hidden: Bool, accessToken: String) async throws {
        let _: VKResponse<JSONValue> = try await client.post(
            path: "/method/audio.editPlaylist", form: common(accessToken).merging([
                "owner_id": String(playlist.ownerID), "playlist_id": String(playlist.playlistID),
                "no_discover": hidden ? "1" : "0"
            ]) { _, new in new }, retryPolicy: .never, responseType: VKResponse<JSONValue>.self)
    }

    func setPlaylistCover(_ playlist: Playlist, jpeg: Data, accessToken: String) async throws {
        let server: VKResponse<VKUploadServer> = try await client.post(
            path: "/method/photos.getAudioPlaylistCoverUploadServer",
            form: common(accessToken).merging([
                "owner_id": String(playlist.ownerID), "playlist_id": String(playlist.playlistID)
            ]) { _, new in new }, responseType: VKResponse<VKUploadServer>.self)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try jpeg.write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        let uploaded = try await client.uploadMultipart(to: server.response.uploadURL, file: file,
            field: "photo", filename: "cover.jpg", mimeType: "image/jpeg", maximumBytes: 10_000_000)
        var form = common(accessToken)
        for key in ["server", "hash", "photo"] {
            guard let value = uploaded.uploadScalar(key), !value.isEmpty else { throw APIError.invalidResponse }
            form[key] = value
        }
        form["owner_id"] = String(playlist.ownerID)
        form["playlist_id"] = String(playlist.playlistID)
        let saved: VKResponse<JSONValue> = try await client.post(path: "/method/photos.saveAudioPlaylistCover",
            form: form, retryPolicy: .never, responseType: VKResponse<JSONValue>.self)
        let photo: JSONValue
        if case let .array(items) = saved.response, let first = items.first { photo = first }
        else { photo = saved.response }
        guard let photoID = photo.uploadScalar("id"), let ownerID = photo.uploadScalar("owner_id") else {
            throw APIError.invalidResponse
        }
        let _: VKResponse<JSONValue> = try await client.post(path: "/method/audio.setPlaylistCoverPhoto",
            form: common(accessToken).merging([
                "owner_id": String(playlist.ownerID), "playlist_id": String(playlist.playlistID),
                "photo_id": "\(ownerID)_\(photoID)"
            ]) { _, new in new }, retryPolicy: .never, responseType: VKResponse<JSONValue>.self)
    }

    func uploadAudio(file: URL, artist: String, title: String, accessToken: String) async throws -> Track {
        let server: VKResponse<VKUploadServer> = try await client.post(path: "/method/audio.getUploadServer",
            form: common(accessToken), responseType: VKResponse<VKUploadServer>.self)
        let uploaded = try await client.uploadMultipart(to: server.response.uploadURL, file: file,
            field: "file", filename: "audio.mp3", mimeType: "audio/mpeg", maximumBytes: VKUploadPolicy.maximumAudioBytes)
        var form = common(accessToken)
        for key in ["server", "audio", "hash"] {
            guard let value = uploaded.uploadScalar(key), !value.isEmpty else { throw APIError.invalidResponse }
            form[key] = value
        }
        form["artist"] = artist
        form["title"] = title
        let saved: VKResponse<Track> = try await client.post(path: "/method/audio.save", form: form,
            retryPolicy: .never, responseType: VKResponse<Track>.self)
        guard saved.response.trackID > 0 else { throw APIError.invalidResponse }
        return saved.response
    }

    func broadcast(track: Track?, accessToken: String) async throws {
        var form = common(accessToken)
        if let track { form["audio"] = track.id }
        let _: VKResponse<JSONValue> = try await client.post(path: "/method/audio.setBroadcast", form: form,
            retryPolicy: .never, responseType: VKResponse<JSONValue>.self)
    }

    func reportPlayback(events: [VKListeningEvent], accessToken: String) async throws {
        guard !events.isEmpty else { return }
        let encoded = try JSONEncoder().encode(events)
        let _: VKResponse<JSONValue> = try await client.post(path: "/method/stats.trackEvents",
            form: common(accessToken).merging(["events": String(decoding: encoded, as: UTF8.self)]) { _, new in new },
            retryPolicy: .never, responseType: VKResponse<JSONValue>.self)
    }
}

enum VKLibraryPagePolicy {
    static func next(offset: Int, received: Int, total: Int) -> Int? {
        guard offset >= 0, received > 0, offset <= Int.max - received else { return nil }
        let next = offset + received
        return next < total ? next : nil
    }
}

struct VKUploadServer: Decodable, Sendable {
    let uploadURL: URL
    enum CodingKeys: String, CodingKey { case uploadURL = "upload_url" }
}

extension JSONValue {
    func uploadScalar(_ key: String) -> String? {
        guard case let .object(fields) = self, let value = fields[key] else { return nil }
        switch value {
        case let .string(text): return text
        case let .number(number) where number.isFinite:
            return String(format: "%.0f", number)
        default: return nil
        }
    }
}

enum VKUploadPolicy {
    static let maximumAudioBytes: Int64 = 200_000_000
    static func accepts(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased() else { return false }
        return ["vk.com", "vkuseraudio.net", "vkuseraudio.com", "userapi.com", "vkuserphoto.ru", "vk-cdn.net"]
            .contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
