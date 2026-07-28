import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var player: AudioPlayer

    var body: some View {
        if let track = player.currentTrack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button {
                        player.isPlayerPresented = true
                    } label: {
                        HStack(spacing: 12) {
                            AsyncArtwork(url: track.artworkURL, size: 46)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title)
                                    .font(.subheadline.bold())
                                    .lineLimit(1)
                                Text(track.artist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        player.playPause()
                    } label: {
                        Image(
                            systemName: player.isPlaying
                                ? "pause.fill"
                                : "play.fill"
                        )
                        .font(.title3)
                        .frame(width: 34, height: 34)
                    }

                    Button {
                        player.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .frame(width: 34, height: 34)
                    }
                }
                .padding(9)

                GeometryReader { proxy in
                    Capsule()
                        .fill(.primary.opacity(0.1))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(.tint)
                                .frame(
                                    width: proxy.size.width * progress
                                )
                        }
                }
                .frame(height: 2)
                .padding(.horizontal, 12)
            }
            .adaptiveGlass(
                in: RoundedRectangle(cornerRadius: 18),
                interactive: true
            )
        }
    }

    private var progress: CGFloat {
        guard player.duration > 0 else { return 0 }
        return CGFloat(
            min(max(player.elapsedTime / player.duration, 0), 1)
        )
    }
}
