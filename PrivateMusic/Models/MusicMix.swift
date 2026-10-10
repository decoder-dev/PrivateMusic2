import Foundation

struct MixCurator: Hashable, Sendable, Codable {
    let id: String
    let displayName: String
    let photoURL: URL?

    var isUsable: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        streamOptions: String? = nil
    ) {
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
            curator: curator
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
            sectionTitle: trimmed,
            curator: curator,
            streamOptions: streamOptions
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
            streamOptions: streamOptions ?? other.streamOptions
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
