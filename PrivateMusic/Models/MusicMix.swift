import Foundation

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

    init(
        id: String,
        title: String,
        subtitle: String,
        artworkURL: URL?,
        matchPercent: Int? = nil,
        isSocial: Bool = false,
        sectionTitle: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.matchPercent = matchPercent
        self.isSocial = isSocial
        self.sectionTitle = sectionTitle
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
            sectionTitle: trimmed
        )
    }

    static let common = MusicMix(
        id: "common",
        title: L10n.text("Составлено Селеной"),
        subtitle: L10n.text("Селена подбирает музыку под ваш вкус"),
        artworkURL: nil,
        matchPercent: nil,
        isSocial: false,
        sectionTitle: nil
    )
}
