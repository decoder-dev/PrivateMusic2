import Foundation

/// Mixes and new releases both live inside the same `catalog.getAudio`
/// response blocks, so a single fetch parses both instead of issuing two
/// independent requests to the same VK endpoint.
struct CatalogSections: Sendable, Equatable {
    let mixes: [MusicMix]
    let newReleases: [Album]
}
