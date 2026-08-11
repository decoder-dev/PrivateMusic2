import Foundation

enum JSONValue: Codable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var tracks: [Track] {
        var result: [Track] = []
        collectTracks(into: &result)
        var ids = Set<String>()
        return result.filter { ids.insert($0.id).inserted }
    }

    /// Top-level `audio.get` / playlist items array only — skips nested
    /// playlist metadata tracks that recursive `tracks` would also collect.
    var libraryAudioItems: [Track] {
        guard case let .object(object) = self,
              case let .array(values)? = object["items"] else {
            return tracks
        }
        var result: [Track] = []
        for value in values {
            if case let .object(item) = value,
               item["owner_id"] != nil,
               item["artist"] != nil,
               item["title"] != nil,
               let data = try? JSONEncoder().encode(value),
               let track = try? JSONDecoder().decode(Track.self, from: data) {
                result.append(track)
            }
        }
        return result
    }

    /// The `audio.getPlaylists` page as VK sent it, one raw entry per
    /// element.
    ///
    /// The entries normally sit in a top-level `items`, but the same payload
    /// has come back with part of the page under a `playlists` / `albums` /
    /// `response` block, under `blocks[].items`, and with each entry wrapped
    /// in a `playlist` object. Stopping at the first block that held
    /// anything left the shelf with whichever handful of entries happened to
    /// be there — one card out of eight in the reported case — so every
    /// block the payload used is merged here instead.
    var libraryEntryValues: [JSONValue] { libraryEntryPage.values }

    /// Raw entries in the requested window — what the next offset has to
    /// advance by, whether or not every entry decoded.
    ///
    /// Only the documented `items` block describes the window VK answered
    /// with. Entries merged from a sibling block are extra copies of the
    /// same list rather than a continuation of it, so they never move the
    /// offset: advancing past them would step over entries VK has not sent
    /// yet.
    var libraryItemCount: Int { libraryEntryPage.rawCount }

    /// One `audio.getPlaylists` page, merged across every block that carried
    /// entries.
    private var libraryEntryPage: LibraryEntryPage {
        if case let .array(values) = self {
            return LibraryEntryPage(values: values, rawCount: values.count)
        }
        guard case let .object(object) = self else {
            return LibraryEntryPage(values: [], rawCount: 0)
        }

        var window: [JSONValue] = []
        var hasWindow = false
        switch object["items"] {
        case .array, .object:
            hasWindow = true
            object["items"]?.collectLibraryEntries(into: &window, depth: 0)
            // An empty `items` is how VK says the list ended. Looking
            // further would restart a walk that has already finished.
            if window.isEmpty {
                return LibraryEntryPage(values: [], rawCount: 0)
            }
        default:
            break
        }

        var merged: [JSONValue] = []
        var seenIdentities = Set<String>()
        Self.merge(window, into: &merged, seen: &seenIdentities)
        for key in Self.siblingEntryKeys {
            guard let block = object[key] else { continue }
            var entries: [JSONValue] = []
            block.collectLibraryEntries(into: &entries, depth: 0)
            Self.merge(entries, into: &merged, seen: &seenIdentities)
        }
        return LibraryEntryPage(
            values: merged,
            rawCount: hasWindow ? window.count : merged.count
        )
    }

    /// Blocks that have carried a copy of the playlist list next to — or
    /// instead of — the documented `items`.
    private static let siblingEntryKeys = [
        "playlists", "albums", "response", "list", "blocks", "sections"
    ]

    /// Blocks to descend through while looking for entries. Anything else
    /// an entry carries (`original`, `thumbs`, `owner`, …) is part of the
    /// entry, not a list of its own.
    private static let entryBlockKeys = [
        "items", "playlists", "albums", "response", "list", "blocks",
        "sections"
    ]

    /// Guards against a self-referential payload sending the walk down
    /// forever. Six levels clear every nesting VK has been seen to use
    /// (`response.blocks[].items[].playlist`).
    private static let maximumEntryDepth = 6

    /// Appends entries that are not already in `result`, matching on the
    /// owner-scoped id so the same playlist arriving under two blocks
    /// renders one card. Values that carry no id are kept as they are: they
    /// decode to nothing, but they are part of the raw page.
    private static func merge(
        _ values: [JSONValue],
        into result: inout [JSONValue],
        seen: inout Set<String>
    ) {
        for value in values {
            if let identity = value.libraryEntryIdentity {
                guard seen.insert(identity).inserted else { continue }
            }
            result.append(value)
        }
    }

    /// Flattens a block into the entries it holds, descending only through
    /// the keys a list can hide behind and stopping at anything that is
    /// already an entry.
    private func collectLibraryEntries(
        into result: inout [JSONValue],
        depth: Int
    ) {
        guard depth <= Self.maximumEntryDepth else { return }
        switch self {
        case let .array(values):
            for value in values {
                value.collectLibraryEntries(into: &result, depth: depth + 1)
            }
        case let .object(object):
            if libraryEntryObject != nil {
                result.append(self)
                return
            }
            let blocks = Self.entryBlockKeys.compactMap { object[$0] }
            guard blocks.isEmpty else {
                for block in blocks {
                    block.collectLibraryEntries(
                        into: &result,
                        depth: depth + 1
                    )
                }
                return
            }
            // An ad row, an audio row, an entry VK sent without an id:
            // nothing decodes from it, but it still occupies a slot in the
            // page VK answered with. The block itself never does.
            if depth > 0 { result.append(self) }
        default:
            if depth > 0 { result.append(self) }
        }
    }

    /// Owner-scoped id of the entry a value carries, or `nil` when it
    /// carries no entry at all.
    private var libraryEntryIdentity: String? {
        guard let object = libraryEntryObject,
              let id = object["id"]?.stringValue,
              let ownerID = object["owner_id"]?.stringValue else {
            return nil
        }
        return "\(ownerID)_\(id)"
    }

    /// `audio.getPlaylists` entries, decoded one by one so a single
    /// undecodable entry cannot hide the rest of the page the way a strict
    /// whole-page decode did. Followed albums ride along in the same list
    /// and belong on the Albums shelf, so they are skipped here.
    ///
    /// Only `id` and `owner_id` are required. Demanding a `title` too
    /// dropped playlists VK returned without one — a shelf card with no
    /// caption is still a playlist you can open, an absent card is not.
    var libraryPlaylistItems: [Playlist] {
        var result: [Playlist] = []
        for value in libraryEntryValues {
            guard let item = value.libraryEntryObject,
                  !item.looksLikeFollowedAlbum,
                  let playlist = item.decodedEntry(Playlist.self) else {
                continue
            }
            result.append(playlist)
        }
        return result
    }

    /// `audio.getPlaylists` entries for the Albums shelf, which asks for
    /// `filters=albums`.
    ///
    /// The shelf used to ask for `filters=followed,albums`. `followed` is a
    /// playlist filter, not a qualifier on `albums`: VK unions the two, so
    /// that request answered with every playlist saved from another person
    /// alongside the releases. Each of them decoded as an `Album`, and —
    /// while the playlist shelf still subtracted the ids this list reported
    /// — was taken off Медиатека entirely, which is «ОНИ НЕ ВСЕ». That
    /// subtraction is gone: this list only fills the Albums shelf now.
    var libraryFollowedAlbumItems: [Album] {
        var result: [Album] = []
        for value in libraryEntryValues {
            guard let item = value.libraryEntryObject,
                  item.belongsOnAlbumsShelf,
                  let album = item.decodedEntry(Album.self) else {
                continue
            }
            result.append(album)
        }
        return result
    }

    /// The entry a block wrapped around, or the entry itself. Objects that
    /// carry a `duration` are audio rows, never playlist entries.
    ///
    /// The nested object wins: a wrapper carries an owner-scoped id of its
    /// own often enough, and reading that instead of the playlist it holds
    /// produced a card whose id opens nothing.
    private var libraryEntryObject: [String: JSONValue]? {
        guard case let .object(object) = self else { return nil }
        for key in ["playlist", "album", "audio_playlist"] {
            if case let .object(nested)? = object[key], nested.isLibraryEntry {
                return nested
            }
        }
        return object.isLibraryEntry ? object : nil
    }

    var libraryTotalCount: Int? {
        guard case let .object(object) = self,
              case let .number(value)? = object["count"] else {
            return nil
        }
        return Int(value.rounded())
    }

    var musicMixes: [MusicMix] {
        var collected: [MusicMix] = []
        collectMixes(into: &collected)
        var order: [String] = []
        var byID: [String: MusicMix] = [:]
        for mix in collected {
            if let existing = byID[mix.id] {
                byID[mix.id] = existing.merging(richer: mix)
            } else {
                order.append(mix.id)
                byID[mix.id] = mix
            }
        }
        return order.compactMap { byID[$0] }
    }

    /// Section list from `catalog.getAudio` (`response.catalog.sections`).
    /// Real section ids must be passed to `catalog.getSection` — guessed
    /// names like `audio_stream_mixes` are not stable.
    var catalogSections: [CatalogSectionRef] {
        var result: [CatalogSectionRef] = []
        collectCatalogSections(into: &result)
        var ids = Set<String>()
        return result.filter { ids.insert($0.id).inserted }
    }

    /// Scans a `catalog.getAudio` / `catalog.getSection` response for album
    /// blocks (official releases carry `main_artists`/`year`, which plain
    /// user playlists never have).
    var releaseAlbums: [Album] {
        var result: [Album] = []
        collectAlbums(into: &result)
        var ids = Set<String>()
        return result.filter { ids.insert($0.id).inserted }
    }

    var artists: [VKArtist] {
        var result: [VKArtist] = []
        collectArtists(into: &result)
        var ids = Set<String>()
        return result.filter { ids.insert($0.id).inserted }
    }

    var directAudioItems: [JSONValue]? {
        guard case let .object(object) = self,
              let audios = object["audios"] else {
            return nil
        }
        switch audios {
        case let .array(values):
            return values
        case .null:
            return []
        default:
            return nil
        }
    }

    private func collectTracks(into result: inout [Track]) {
        switch self {
        case let .object(object):
            if object["owner_id"] != nil,
               object["artist"] != nil,
               object["title"] != nil,
               let data = try? JSONEncoder().encode(self),
               let track = try? JSONDecoder().decode(Track.self, from: data) {
                result.append(track)
                return
            }
            object.values.forEach { $0.collectTracks(into: &result) }
        case let .array(values):
            values.forEach { $0.collectTracks(into: &result) }
        default:
            break
        }
    }

    private func collectMixes(into result: inout [MusicMix]) {
        switch self {
        case let .object(object):
            let type = object["data_type"]?.stringValue
                ?? object["type"]?.stringValue
                ?? ""
            let explicitID = object["mix_id"]?.stringValue
            let isMix = explicitID != nil
                || type.localizedCaseInsensitiveContains("stream_mix")
            if isMix,
               let id = explicitID ?? object["id"]?.stringValue,
               !id.isEmpty {
                let title = object["title"]?.stringValue
                    ?? object["name"]?.stringValue
                    ?? L10n.text("VK Микс")
                let subtitle = object["subtitle"]?.stringValue
                    ?? object["description"]?.stringValue
                    ?? object["caption"]?.stringValue
                    ?? L10n.text("Персональная подборка VK")
                let matchPercent = object.mixMatchPercent
                let curator = object.mixCurator
                let social = object.looksLikeSocialMix(
                    type: type,
                    title: title,
                    subtitle: subtitle,
                    matchPercent: matchPercent
                ) || (curator?.isUsable == true)
                result.append(
                    MusicMix(
                        id: id,
                        title: title,
                        subtitle: subtitle,
                        artworkURL: object.mixCoverURL,
                        matchPercent: matchPercent,
                        isSocial: social,
                        curator: curator
                    )
                )
            }
            object.values.forEach { $0.collectMixes(into: &result) }
        case let .array(values):
            values.forEach { $0.collectMixes(into: &result) }
        default:
            break
        }
    }

    private func collectCatalogSections(
        into result: inout [CatalogSectionRef]
    ) {
        switch self {
        case let .object(object):
            if case let .object(catalog)? = object["catalog"],
               case let .array(sections)? = catalog["sections"] {
                for section in sections {
                    if let parsed = section.asCatalogSection {
                        result.append(parsed)
                    }
                }
            }
            if case let .array(sections)? = object["sections"] {
                for section in sections {
                    if let parsed = section.asCatalogSection {
                        result.append(parsed)
                    }
                }
            }
            if let parsed = asCatalogSection {
                result.append(parsed)
            }
            object.values.forEach { $0.collectCatalogSections(into: &result) }
        case let .array(values):
            values.forEach { $0.collectCatalogSections(into: &result) }
        default:
            break
        }
    }

    private var asCatalogSection: CatalogSectionRef? {
        guard case let .object(object) = self else { return nil }
        let id = object["id"]?.stringValue
            ?? object["section_id"]?.stringValue
        guard let id, !id.isEmpty else { return nil }
        // Mix / audio objects also have id+title — require section-ish shape.
        let type = object["type"]?.stringValue
            ?? object["data_type"]?.stringValue
            ?? ""
        let url = object["url"]?.stringValue
        let looksLikeSection = url?.contains("audios") == true
            || type.localizedCaseInsensitiveContains("section")
            || object["blocks"] != nil
            || object["next_from"] != nil
        guard looksLikeSection || (object["title"] != nil && url != nil) else {
            return nil
        }
        return CatalogSectionRef(
            id: id,
            title: object["title"]?.stringValue
                ?? object["name"]?.stringValue
                ?? "",
            url: url
        )
    }

    private func collectAlbums(into result: inout [Album]) {
        switch self {
        case let .object(object):
            let looksLikeAlbum = object["owner_id"] != nil
                && object["id"] != nil
                && object["title"] != nil
                && (object["main_artists"] != nil || object["year"] != nil)
            if looksLikeAlbum,
               let data = try? JSONEncoder().encode(self),
               let album = try? JSONDecoder().decode(Album.self, from: data) {
                result.append(album)
                return
            }
            object.values.forEach { $0.collectAlbums(into: &result) }
        case let .array(values):
            values.forEach { $0.collectAlbums(into: &result) }
        default:
            break
        }
    }

    private func collectArtists(into result: inout [VKArtist]) {
        switch self {
        case let .object(object):
            if let artist = object.asVKArtist {
                result.append(artist)
            }
            object.values.forEach { $0.collectArtists(into: &result) }
        case let .array(values):
            values.forEach { $0.collectArtists(into: &result) }
        default:
            break
        }
    }

    fileprivate var stringValue: String? {
        switch self {
        case let .string(value): value
        case let .number(value):
            value.rounded() == value ? String(Int(value)) : String(value)
        default: nil
        }
    }

    fileprivate var numberValue: Double? {
        switch self {
        case let .number(value): value
        case let .string(value):
            Double(
                value.replacingOccurrences(of: "%", with: "")
                    .trimmingCharacters(in: .whitespaces)
            )
        default: nil
        }
    }
}

/// An `audio.getPlaylists` page after every block that carried entries has
/// been merged into one list.
private struct LibraryEntryPage {
    /// Merged entries, in payload order, one per playlist VK named.
    let values: [JSONValue]
    /// Size of the window VK answered with, counted before the merge.
    let rawCount: Int
}

private extension Dictionary where Key == String, Value == JSONValue {
    /// An `audio.getPlaylists` entry: owner-scoped id, and not an audio row.
    var isLibraryEntry: Bool {
        self["id"] != nil && self["owner_id"] != nil && self["duration"] == nil
    }

    /// Re-decodes the entry through its own `Decodable`. Encoding the
    /// dictionary rather than the enclosing value keeps a wrapper block off
    /// the payload the model sees.
    func decodedEntry<Item: Decodable>(_ type: Item.Type) -> Item? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// The entry reduced to the fields `LibraryPlaylistEntryPolicy` reads.
    var libraryPlaylistEntry: LibraryPlaylistEntry {
        var hasMainArtists = false
        if case let .array(artists)? = self["main_artists"], !artists.isEmpty {
            hasMainArtists = true
        }
        var hasOriginal = false
        if case .object? = self["original"] { hasOriginal = true }
        return LibraryPlaylistEntry(
            albumType: self["album_type"]?.stringValue,
            hasMainArtists: hasMainArtists,
            hasReleaseYear: self["year"]?.numberValue != nil
                || self["original_year"]?.numberValue != nil,
            vkType: self["type"]?.numberValue.map { Int($0.rounded()) },
            hasOriginalPlaylist: hasOriginal
        )
    }

    /// A followed release returned by `audio.getPlaylists`, which the Albums
    /// shelf already covers via `filters=albums`. See
    /// `LibraryPlaylistEntryPolicy` for why the test stays this narrow.
    var looksLikeFollowedAlbum: Bool {
        LibraryPlaylistEntryPolicy.looksLikeFollowedAlbum(libraryPlaylistEntry)
    }

    /// An entry of the `filters=albums` list that is a release rather than a
    /// playlist VK left in the answer.
    var belongsOnAlbumsShelf: Bool {
        LibraryPlaylistEntryPolicy.belongsOnAlbumsShelf(libraryPlaylistEntry)
    }

    var mixMatchPercent: Int? {
        let keys = [
            "percent", "match_percent", "match", "compatibility",
            "similarity", "score", "overlap"
        ]
        for key in keys {
            guard let value = self[key]?.numberValue else { continue }
            let percent = value <= 1 ? value * 100 : value
            let rounded = Int(percent.rounded())
            if (1...100).contains(rounded) { return rounded }
        }
        return nil
    }

    /// Mix cover only — never recurse into nested owner/user avatars.
    var mixCoverURL: URL? {
        let preferredKeys = [
            "photo_1200", "photo_600", "photo_300", "photo_270",
            "cover_url", "thumb_url", "image"
        ]
        for key in preferredKeys {
            if case let .string(raw)? = self[key],
               let url = URL.secureRemoteURL(raw) {
                return url
            }
            if case let .object(nested)? = self[key],
               let url = nested.firstRemoteURL {
                return url
            }
        }
        if case let .array(thumbs)? = self["thumbs"]
            ?? self["images"]
            ?? self["photos"] {
            for item in thumbs {
                if case let .object(object) = item,
                   let url = object.firstRemoteURL {
                    return url
                }
                if case let .string(raw) = item,
                   let url = URL.secureRemoteURL(raw) {
                    return url
                }
            }
        }
        return nil
    }

    var mixCurator: MixCurator? {
        let candidates: [[String: JSONValue]] = [
            self,
            objectValue("owner"),
            objectValue("user"),
            objectValue("profile"),
            objectValue("friend"),
            objectValue("author")
        ].compactMap { $0 }

        for object in candidates {
            let id = object["id"]?.stringValue
                ?? object["user_id"]?.stringValue
                ?? object["owner_id"]?.stringValue
            let first = object["first_name"]?.stringValue
            let last = object["last_name"]?.stringValue
            let joinedName = [first, last]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let name = object["name"]?.stringValue
                ?? object["title"]?.stringValue
                ?? (joinedName.isEmpty ? nil : joinedName)
            let trimmed = name?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, !trimmed.isEmpty else { continue }
            let photo = object["photo_200"]?.stringValue
                ?? object["photo_100"]?.stringValue
                ?? object["photo"]?.stringValue
            return MixCurator(
                id: id ?? trimmed,
                displayName: trimmed,
                photoURL: photo.flatMap(URL.secureRemoteURL)
            )
        }
        return nil
    }

    private func objectValue(_ key: String) -> [String: JSONValue]? {
        if case let .object(value)? = self[key] {
            return value
        }
        return nil
    }

    func looksLikeSocialMix(
        type: String,
        title: String,
        subtitle: String,
        matchPercent: Int?
    ) -> Bool {
        if matchPercent != nil { return true }
        let blob = "\(type) \(title) \(subtitle)".lowercased()
        let markers = [
            "friend", "friends", "taste", "mutual", "совпад",
            "друг", "слушайте друг", "listen together"
        ]
        return markers.contains { blob.contains($0) }
    }

    var firstRemoteURL: URL? {
        let preferredKeys = [
            "photo_1200", "photo_600", "photo_300", "photo_270",
            "cover_url", "url"
        ]
        for key in preferredKeys {
            if case let .string(raw)? = self[key],
               let url = URL.secureRemoteURL(raw) {
                return url
            }
        }
        for value in values {
            switch value {
            case let .object(object):
                if let url = object.firstRemoteURL { return url }
            case let .array(values):
                for item in values {
                    if case let .object(object) = item,
                       let url = object.firstRemoteURL {
                        return url
                    }
                }
            default:
                continue
            }
        }
        return nil
    }

    var asVKArtist: VKArtist? {
        let name = self["name"]?.stringValue
            ?? self["title"]?.stringValue
        guard let name, !name.isEmpty else { return nil }
        let id = self["id"]?.stringValue
            ?? self["artist_id"]?.stringValue
            ?? self["domain"]?.stringValue
        guard let id, !id.isEmpty else { return nil }
        // Reject track / album shaped objects that also have id+name.
        if self["owner_id"] != nil, self["duration"] != nil { return nil }
        if self["owner_id"] != nil, self["main_artists"] != nil { return nil }
        let type = self["type"]?.stringValue
            ?? self["data_type"]?.stringValue
            ?? ""
        if !type.isEmpty,
           !type.localizedCaseInsensitiveContains("artist"),
           self["photo"] == nil,
           self["photo_600"] == nil,
           firstRemoteURL == nil {
            return nil
        }
        return VKArtist(
            id: id,
            name: name,
            photoURL: firstRemoteURL,
            isAlbumCover: self["is_album_cover"]?.boolValue == true
        )
    }
}

private extension JSONValue {
    var boolValue: Bool? {
        switch self {
        case let .bool(value): value
        case let .number(value): value != 0
        case let .string(value):
            ["1", "true", "yes"].contains(value.lowercased())
        default: nil
        }
    }
}
