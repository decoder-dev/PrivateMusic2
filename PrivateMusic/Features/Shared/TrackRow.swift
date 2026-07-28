import SwiftUI
import Foundation

struct TrackRow: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var settings: AppSettings
    let track: Track
    let queue: [Track]

    var body: some View {
        Button {
            Haptics.selection()
            player.play(track, in: queue)
        } label: {
            HStack(spacing: 12) {
                AsyncArtwork(url: track.artworkURL, size: 52)

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.headline)
                        .foregroundStyle(
                            isCurrent
                                ? settings.theme.accent
                                : Color.primary
                        )
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(track.duration.formattedDuration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Image(
                    systemName: isCurrent && player.isPlaying
                        ? "waveform"
                        : "play.fill"
                )
                    .font(.caption)
                    .foregroundStyle(
                        isCurrent
                            ? settings.theme.accent
                            : Color.secondary
                    )
                    .frame(width: 22, height: 22)
                    .background(
                        Color(uiColor: .tertiarySystemFill),
                        in: Circle()
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PremiumPressStyle())
        .contextMenu {
            Button {
                player.playNext(track)
            } label: {
                Label(
                    "Играть следующим",
                    systemImage: "text.line.first.and.arrowtriangle.forward"
                )
            }
            Button {
                Haptics.open()
                player.play(track, in: queue)
                player.isPlayerPresented = true
            } label: {
                Label("Открыть плеер", systemImage: "play.circle")
            }
        }
    }

    private var isCurrent: Bool {
        player.currentTrack?.id == track.id
    }
}

extension TimeInterval {
    var formattedDuration: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(self)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
