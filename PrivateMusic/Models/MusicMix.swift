import Foundation

struct MusicMix: Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let artworkURL: URL?

    static let common = MusicMix(
        id: "common",
        title: L10n.text("Мой микс"),
        subtitle: L10n.text("Бесконечная персональная подборка VK"),
        artworkURL: nil
    )
}
