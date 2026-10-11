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
        if mix.streamMixID == MusicMix.common.id { return .station }
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
    @State private var backdrop: MixBackdropPalette?
    @State private var backdropResolved = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            } else if let backdrop {
                MixBackdropView(palette: backdrop)
            } else if selectedTracks.count >= 4, !awaitingBackdrop {
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
        .task(id: mix.backdropURL) {
            guard mix.artworkURL == nil, let url = mix.backdropURL else {
                backdrop = nil
                backdropResolved = true
                return
            }
            backdropResolved = false
            backdrop = await MixBackdropStore.shared.palette(for: url)
            backdropResolved = true
        }
        // One calm cross-fade when a better cover arrives, never a jump.
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.25),
            value: coverStage
        )
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

    /// VK's backdrop is on its way: keep the neutral cover instead of
    /// flashing a track collage that is about to be replaced.
    private var awaitingBackdrop: Bool {
        mix.artworkURL == nil && mix.backdropURL != nil && !backdropResolved
    }

    private var coverStage: Int {
        if backdrop != nil { return 2 }
        if selectedTracks.count >= 4, !awaitingBackdrop { return 1 }
        return 0
    }

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
                    settings.surfaceColor,
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

/// A mix backdrop painted from its four corner colours, with the three
/// quarter-circle ripples the official mix cover has in its bottom corner.
struct MixBackdropView: View {
    let palette: MixBackdropPalette

    var body: some View {
        GeometryReader { proxy in
            let side = max(proxy.size.width, proxy.size.height)
            ZStack(alignment: .bottomLeading) {
                gradient
                ForEach([0.31, 0.59, 0.92], id: \.self) { fraction in
                    Circle()
                        .fill(.white.opacity(0.08))
                        .frame(width: side * fraction * 2)
                        .offset(
                            x: -side * fraction,
                            y: side * fraction
                        )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }

    @ViewBuilder
    private var gradient: some View {
        if #available(iOS 18.0, *) {
            MeshGradient(
                width: 2,
                height: 2,
                points: [[0, 0], [1, 0], [0, 1], [1, 1]],
                colors: [
                    palette.topLeading.color,
                    palette.topTrailing.color,
                    palette.bottomLeading.color,
                    palette.bottomTrailing.color
                ]
            )
        } else {
            ZStack {
                LinearGradient(
                    colors: [
                        palette.topLeading.color,
                        palette.bottomTrailing.color
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                LinearGradient(
                    colors: [
                        palette.topTrailing.color,
                        palette.bottomLeading.color
                    ],
                    startPoint: .topTrailing,
                    endPoint: .bottomLeading
                )
                .opacity(0.5)
            }
        }
    }
}

private extension MixBackdropPalette.RGB {
    var color: Color {
        Color(red: red, green: green, blue: blue)
    }
}
