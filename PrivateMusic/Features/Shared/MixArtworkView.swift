import SwiftUI

struct MixArtworkView: View {
    @EnvironmentObject private var settings: AppSettings
    let mix: MusicMix
    let tracks: [Track]
    let size: CGFloat

    var body: some View {
        Group {
            if let artworkURL = mix.artworkURL {
                tile(url: artworkURL, dimension: size)
            } else if selectedTracks.count >= 4 {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        tile(
                            url: selectedTracks[0].artworkURL,
                            dimension: size / 2
                        )
                        tile(
                            url: selectedTracks[1].artworkURL,
                            dimension: size / 2
                        )
                    }
                    HStack(spacing: 0) {
                        tile(
                            url: selectedTracks[2].artworkURL,
                            dimension: size / 2
                        )
                        tile(
                            url: selectedTracks[3].artworkURL,
                            dimension: size / 2
                        )
                    }
                }
            } else {
                ZStack {
                    LinearGradient(
                        colors: [
                            settings.theme.accent.opacity(0.78),
                            settings.theme.surface
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "waveform")
                        .font(.system(size: size * 0.25, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(
            RoundedRectangle(
                cornerRadius: PremiumLayout.artworkRadius(for: size),
                style: .continuous
            )
        )
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

    private func tile(url: URL?, dimension: CGFloat) -> some View {
        CachedRemoteImage(url: url) { image in
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
        .frame(width: dimension, height: dimension)
        .clipped()
    }
}
