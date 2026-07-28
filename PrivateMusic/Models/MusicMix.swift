import Foundation

struct MusicMix: Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let artworkURL: URL?

    static let common = MusicMix(
        id: "common",
        title: "Мой микс",
        subtitle: "Бесконечная персональная подборка VK",
        artworkURL: nil
    )
}
