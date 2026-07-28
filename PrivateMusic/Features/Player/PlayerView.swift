import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Brand.violet.opacity(0.42), Brand.background],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                if let track = player.currentTrack {
                    VStack(spacing: 28) {
                        Spacer()
                        AsyncArtwork(url: track.artworkURL, size: 310)
                            .shadow(color: .black.opacity(0.45), radius: 30, y: 18)

                        VStack(spacing: 7) {
                            Text(track.title)
                                .font(.title2.bold())
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                            Text(track.artist)
                                .foregroundStyle(.secondary)
                        }

                        VStack(spacing: 8) {
                            Slider(
                                value: Binding(
                                    get: { player.elapsedTime },
                                    set: { player.seek(to: $0) }
                                ),
                                in: 0...max(player.duration, 1)
                            )
                            HStack {
                                Text(player.elapsedTime.formattedDuration)
                                Spacer()
                                Text(player.duration.formattedDuration)
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 48) {
                            Button {
                                player.previous()
                            } label: {
                                Image(systemName: "backward.fill")
                            }
                            Button {
                                player.playPause()
                            } label: {
                                Image(
                                    systemName: player.isPlaying
                                        ? "pause.circle.fill"
                                        : "play.circle.fill"
                                )
                                .font(.system(size: 72))
                            }
                            Button {
                                player.next()
                            } label: {
                                Image(systemName: "forward.fill")
                            }
                        }
                        .font(.title)

                        Spacer()
                    }
                    .padding(.horizontal, 26)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Закрыть") {
                        dismiss()
                    }
                }
            }
        }
    }
}
