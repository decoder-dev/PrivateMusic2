import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var player: AudioPlayer

    var body: some View {
        if let track = player.currentTrack {
            HStack(spacing: 12) {
                Button {
                    player.isPlayerPresented = true
                } label: {
                    HStack(spacing: 12) {
                        AsyncArtwork(url: track.artworkURL, size: 48)
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
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
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
            .padding(10)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(.white.opacity(0.08))
            }
        }
    }
}

