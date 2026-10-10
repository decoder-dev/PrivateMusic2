import Foundation

/// One selectable chip of VK's «Настроить микс» sheet (mood, activity,
/// genre, language …).
struct MixTuningOption: Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let isSelected: Bool
}

/// A row of chips such as «Настроение» or «Занятие».
struct MixTuningCategory: Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let allowsMultiple: Bool
    let options: [MixTuningOption]
}

/// What `audio.getStreamMixSettings` reports for one stream mix.
struct MixTuning: Equatable, Sendable {
    let categories: [MixTuningCategory]

    var isEmpty: Bool {
        categories.allSatisfy { $0.options.isEmpty }
    }

    /// Option ids VK already has selected, per category.
    var initialSelection: [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for category in categories {
            let picked = category.options.filter(\.isSelected).map(\.id)
            if !picked.isEmpty { result[category.id] = Set(picked) }
        }
        return result
    }

    /// Compact `mix_options` JSON for the chosen chips, or nil when
    /// nothing is chosen (plain mix).
    static func encode(_ selection: [String: Set<String>]) -> String? {
        var object: [String: JSONValue] = [:]
        for (key, ids) in selection where !ids.isEmpty {
            object[key] = .array(ids.sorted().map { .string($0) })
        }
        guard !object.isEmpty else { return nil }
        return JSONValue.object(object).compactJSON
    }

    /// The personal mix with the chosen chips applied.
    func mix(
        applying selection: [String: Set<String>],
        to base: MusicMix
    ) -> MusicMix {
        guard let options = Self.encode(selection) else {
            return base.untuned
        }
        let chosen = categories.flatMap { category in
            category.options.filter {
                selection[category.id]?.contains($0.id) == true
            }
        }.map(\.title)
        let title = chosen.isEmpty
            ? base.title
            : base.title + " · " + chosen.joined(separator: ", ")
        return MusicMix(
            id: base.streamMixID
                + String(MusicMix.optionsSeparator) + options,
            title: title,
            subtitle: base.subtitle,
            artworkURL: base.artworkURL,
            matchPercent: base.matchPercent,
            isSocial: base.isSocial,
            sectionTitle: base.sectionTitle,
            curator: base.curator,
            streamOptions: options
        )
    }
}

extension JSONValue {
    /// Reads the settings answer without trusting its exact shape: finds
    /// the first `mix_categories` array (or any array of objects that carry
    /// `options`) and maps titles / ids / selected flags tolerantly.
    var mixTuning: MixTuning {
        MixTuning(categories: tuningCategoryArray.compactMap(\.asTuningCategory))
    }

    private var tuningCategoryArray: [JSONValue] {
        switch self {
        case let .object(object):
            for key in ["mix_categories", "categories", "settings"] {
                if case let .array(values)? = object[key],
                   values.contains(where: \.hasTuningOptions) {
                    return values
                }
            }
            for value in object.values {
                let nested = value.tuningCategoryArray
                if !nested.isEmpty { return nested }
            }
            return []
        case let .array(values):
            if values.contains(where: \.hasTuningOptions) { return values }
            for value in values {
                let nested = value.tuningCategoryArray
                if !nested.isEmpty { return nested }
            }
            return []
        default:
            return []
        }
    }

    private var hasTuningOptions: Bool {
        if case let .object(object) = self,
           case .array? = object["options"] {
            return true
        }
        return false
    }

    private var asTuningCategory: MixTuningCategory? {
        guard case let .object(object) = self,
              case let .array(rawOptions)? = object["options"] else {
            return nil
        }
        let title = object["title"]?.tuningString ?? ""
        let id = object["type"]?.tuningString
            ?? object["id"]?.tuningString
            ?? title
        guard !id.isEmpty else { return nil }
        let options = rawOptions.compactMap(\.asTuningOption)
        guard !options.isEmpty else { return nil }
        let multi = object["multi_select"]?.tuningBool
            ?? object["multiselect"]?.tuningBool
            ?? false
        return MixTuningCategory(
            id: id,
            title: title,
            allowsMultiple: multi,
            options: options
        )
    }

    private var asTuningOption: MixTuningOption? {
        switch self {
        case let .string(value) where !value.isEmpty:
            return MixTuningOption(id: value, title: value, isSelected: false)
        case let .object(object):
            let title = object["title"]?.tuningString
                ?? object["name"]?.tuningString
                ?? object["text"]?.tuningString
            let id = object["id"]?.tuningString
                ?? object["option_id"]?.tuningString
                ?? object["value"]?.tuningString
                ?? object["key"]?.tuningString
                ?? title
            guard let id, !id.isEmpty else { return nil }
            let selected = object["selected"]?.tuningBool
                ?? object["is_selected"]?.tuningBool
                ?? object["active"]?.tuningBool
                ?? false
            return MixTuningOption(
                id: id,
                title: title ?? id,
                isSelected: selected
            )
        default:
            return nil
        }
    }

    fileprivate var tuningString: String? {
        switch self {
        case let .string(value): value.isEmpty ? nil : value
        case let .number(value):
            value.rounded() == value ? String(Int(value)) : String(value)
        default: nil
        }
    }

    fileprivate var tuningBool: Bool? {
        switch self {
        case let .bool(value): value
        case let .number(value): value != 0
        case let .string(value): ["1", "true"].contains(value.lowercased())
        default: nil
        }
    }
}
