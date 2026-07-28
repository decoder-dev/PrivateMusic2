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

    var musicMixes: [MusicMix] {
        var result: [MusicMix] = []
        collectMixes(into: &result)
        var ids = Set<String>()
        return result.filter { ids.insert($0.id).inserted }
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
                    ?? "VK Микс"
                let subtitle = object["subtitle"]?.stringValue
                    ?? "Персональная подборка VK"
                result.append(
                    MusicMix(
                        id: id,
                        title: title,
                        subtitle: subtitle,
                        artworkURL: object.firstRemoteURL
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

    private var stringValue: String? {
        switch self {
        case let .string(value): value
        case let .number(value):
            value.rounded() == value ? String(Int(value)) : String(value)
        default: nil
        }
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
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
}
