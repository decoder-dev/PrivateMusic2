import Foundation

struct MixCurator: Hashable, Sendable, Codable {
    let id: String
    let displayName: String
    let photoURL: URL?

    var isUsable: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// What the listener sees. The data comes from VK's mixes, but the product
/// presents them under one name, so VK's own wording never reaches the UI.
enum MixBranding {
    static let name = "Selena"

    private static let vkWord = try? NSRegularExpression(
        pattern: "(?<![\\p{L}\\d])(?:VK|ВК)(?![\\p{L}\\d])",
        options: [.caseInsensitive]
    )

    /// VK's names for the personal mix, in every wording seen in catalogs.
    private static let personalNames: Set<String> = [
        "мой микс", "my mix", "vk микс", "вк микс", "vk mix",
        "микс vk", "микс вк", "mix vk"
    ]

    static func isPersonalName(_ raw: String) -> Bool {
        personalNames.contains(
            raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    /// Replaces the bare word «VK» / «ВК» with the brand; leaves
    /// «ВКонтакте» and everything else alone.
    static func display(_ raw: String) -> String {
        if isPersonalName(raw) { return name }
        guard let vkWord else { return raw }
        let range = NSRange(raw.startIndex..., in: raw)
        return vkWord.stringByReplacingMatches(
            in: raw,
            options: [],
            range: range,
            withTemplate: name
        )
    }
}

struct MusicMix: Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let artworkURL: URL?
    /// Taste-match percentage when VK exposes one (friend / listen-together mixes).
    let matchPercent: Int?
    /// Social / friend taste mixes shown under «Слушайте друг друга».
    let isSocial: Bool
    /// Official catalog section title when the mix came from `catalog.getSection`.
    let sectionTitle: String?
    /// Friend / curator identity when VK exposes one on social mixes.
    let curator: MixCurator?
    /// Compact JSON for `audio.getStreamMixAudios` `mix_options` — set on
    /// tuned variants of one stream mix (mood / activity tiles share the
    /// `common` mix id and differ only by these options).
    let streamOptions: String?
    /// VK's animated backdrop for the mix tile (Lottie); only its colours
    /// are used, see `MixBackdropPalette`.
    let backdropURL: URL?

    /// Separator between VK's `mix_id` and the options digest in `id`, so
    /// two moods of the same stream mix stay distinct in lists and pins.
    static let optionsSeparator: Character = "#"

    init(
        id: String,
        title: String,
        subtitle: String,
        artworkURL: URL?,
        matchPercent: Int? = nil,
        isSocial: Bool = false,
        sectionTitle: String? = nil,
        curator: MixCurator? = nil,
        streamOptions: String? = nil,
        backdropURL: URL? = nil
    ) {
        self.backdropURL = backdropURL
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.matchPercent = matchPercent
        self.isSocial = isSocial || (curator?.isUsable == true)
        self.sectionTitle = sectionTitle
        self.curator = curator
        // A pinned or restored mix only keeps its id — the tuning rides in
        // the id's suffix, so recover it instead of silently playing plain.
        self.streamOptions = streamOptions ?? Self.options(inID: id)
    }

    private static func options(inID id: String) -> String? {
        guard let index = id.firstIndex(of: optionsSeparator) else {
            return nil
        }
        let suffix = String(id[id.index(after: index)...])
        return suffix.isEmpty ? nil : suffix
    }

    /// The id VK itself knows the mix by.
    var streamMixID: String {
        guard let index = id.firstIndex(of: Self.optionsSeparator) else {
            return id
        }
        return String(id[..<index])
    }

    /// Same mix without the tuning, used when VK rejects the options.
    var untuned: MusicMix {
        guard streamOptions != nil else { return self }
        return MusicMix(
            id: streamMixID,
            title: title,
            subtitle: subtitle,
            artworkURL: artworkURL,
            matchPercent: matchPercent,
            isSocial: isSocial,
            sectionTitle: sectionTitle,
            curator: curator,
            backdropURL: backdropURL
        )
    }

    func withSectionTitle(_ title: String?) -> MusicMix {
        guard let title else { return self }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return self }
        return MusicMix(
            id: id,
            title: self.title,
            subtitle: subtitle,
            artworkURL: artworkURL,
            matchPercent: matchPercent,
            isSocial: isSocial,
            sectionTitle: MixBranding.display(trimmed),
            curator: curator,
            streamOptions: streamOptions,
            backdropURL: backdropURL
        )
    }

    func merging(richer other: MusicMix) -> MusicMix {
        MusicMix(
            id: id,
            title: title.isEmpty ? other.title : title,
            subtitle: subtitle.isEmpty ? other.subtitle : subtitle,
            artworkURL: artworkURL ?? other.artworkURL,
            matchPercent: matchPercent ?? other.matchPercent,
            isSocial: isSocial || other.isSocial,
            sectionTitle: sectionTitle ?? other.sectionTitle,
            curator: curator ?? other.curator,
            streamOptions: streamOptions ?? other.streamOptions,
            backdropURL: backdropURL ?? other.backdropURL
        )
    }

    static let common = MusicMix(
        id: "common",
        title: L10n.text("mix.personal_title"),
        subtitle: L10n.text("mix.personal_subtitle"),
        artworkURL: nil,
        matchPercent: nil,
        isSocial: false,
        sectionTitle: nil,
        curator: nil
    )
}
