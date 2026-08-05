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

    var libraryTotalCount: Int? {
        guard case let .object(object) = self,
              case let .number(value)? = object["count"] else {
            return nil
        }
        return Int(value.rounded())
    }

    var musicMixes: [MusicMix] {
        var result: [MusicMix] = []
        collectMixes(into: &result)
        var ids = Set<String>()
        return result.filter { ids.insert($0.id).inserted }
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
                    ?? L10n.text("Персональная подборка VK")
                let matchPercent = object.mixMatchPercent
                let social = object.looksLikeSocialMix(
                    type: type,
                    title: title,
                    subtitle: subtitle,
                    matchPercent: matchPercent
                )
                result.append(
                    MusicMix(
                        id: id,
                        title: title,
                        subtitle: subtitle,
                        artworkURL: object.firstRemoteURL,
                        matchPercent: matchPercent,
                        isSocial: social
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

private extension Dictionary where Key == String, Value == JSONValue {
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
