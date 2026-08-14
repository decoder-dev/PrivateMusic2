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

    init(
        id: String,
        title: String,
        subtitle: String,
        artworkURL: URL?,
        matchPercent: Int? = nil,
        isSocial: Bool = false,
        sectionTitle: String? = nil,
        curator: MixCurator? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.matchPercent = matchPercent
        self.isSocial = isSocial || (curator?.isUsable == true)
        self.sectionTitle = sectionTitle
        self.curator = curator
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
            curator: curator
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
            curator: curator ?? other.curator
        )
    }

    static let common = MusicMix(
        id: "common",
        title: L10n.text("selena.curated_by"),
        subtitle: L10n.text("selena.subtitle"),
        artworkURL: nil,
        matchPercent: nil,
        isSocial: false,
        sectionTitle: nil,
        curator: nil
    )
}
