import SwiftUI

/// What a mix with no cover of its own should be drawn as.
///
/// VK only sends a cover for some mixes, and the app's own «Составлено
/// Селеной» is assembled locally, so it has none by definition. Falling
/// back to one shared grey note left every such mix looking like a
/// missing image rather than a thing you can play — and looking identical
/// to each other. The generated cover is keyed to what the mix *is*, so
/// the station reads with the same colour and glyph as the station bubble
/// on Home rather than as a generic card.
enum MixArtworkFallback {
    static func role(for mix: MusicMix) -> BubbleRole {
        if mix.id == MusicMix.common.id { return .station }
        if mix.isSocial || mix.curator?.isUsable == true { return .artist }
        return .mix
    }

    static func symbol(for mix: MusicMix) -> String {
        switch role(for: mix) {
        case .station: "sparkles"
        case .artist: "person.2.wave.2.fill"
        default: "square.stack.fill"
        }
    }
}

struct MixArtworkView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.displayScale) private var displayScale
    let mix: MusicMix
    let tracks: [Track]
    let size: CGFloat
    var height: CGFloat? = nil
    var cornerRadius: CGFloat? = nil

    var body: some View {
        Group {
            if let artworkURL = mix.artworkURL {
                tile(
                    url: artworkURL,
                    width: size,
                    height: resolvedHeight
                )
            } else if let curatorPhoto = mix.curator?.photoURL,
                      mix.curator?.isUsable == true {
                // A friend's mix already has a face attached to it; using
                // it beats generating a monogram for a mix that is, to the
                // listener, that person.
                tile(
                    url: curatorPhoto,
                    width: size,
                    height: resolvedHeight
                )
            } else if selectedTracks.count >= 4 {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        tile(
                            url: selectedTracks[0].artworkURL,
                            width: size / 2,
                            height: resolvedHeight / 2
                        )
                        tile(
                            url: selectedTracks[1].artworkURL,
                            width: size / 2,
                            height: resolvedHeight / 2
                        )
                    }
                    HStack(spacing: 0) {
                        tile(
                            url: selectedTracks[2].artworkURL,
                            width: size / 2,
                            height: resolvedHeight / 2
                        )
                        tile(
                            url: selectedTracks[3].artworkURL,
                            width: size / 2,
                            height: resolvedHeight / 2
                        )
                    }
                }
            } else {
                let tint = BubblePalette
                    .surface(MixArtworkFallback.role(for: mix), tint: nil)
                    .color
                ZStack {
                    LinearGradient(
                        colors: [tint, tint.opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: MixArtworkFallback.symbol(for: mix))
                        .font(
                            .system(
                                size: min(size, resolvedHeight) * 0.28,
                                weight: .semibold
                            )
                        )
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
        }
        .frame(width: size, height: resolvedHeight)
        .clipShape(
            RoundedRectangle(
                cornerRadius:
                    cornerRadius
                    ?? PremiumLayout.artworkRadius(for: min(size, resolvedHeight)),
                style: .continuous
            )
        )
    }

    private var resolvedHeight: CGFloat { height ?? size }

    private var selectedTracks: [Track] {
        let available = tracks.filter { $0.artworkURL != nil }
        guard !available.isEmpty else { return [] }
        let seed = mix.id.unicodeScalars.reduce(0) {
            ($0 &* 31 &+ Int($1.value)) & 0x7fffffff
        }
        return (0..<min(4, available.count)).map { index in
            available[(seed + index * 7) % available.count]
        }
    }

    private func tile(
        url: URL?,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        CachedRemoteImage(
            url: url,
            maxPixelSize: ArtworkDecodePolicy.maxPixelSize(
                width: width,
                height: height,
                scale: displayScale
            )
        ) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            LinearGradient(
                colors: [
                    settings.theme.surface,
                    settings.theme.secondaryAccent.opacity(0.42)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .frame(width: width, height: height)
        .clipped()
    }
}
