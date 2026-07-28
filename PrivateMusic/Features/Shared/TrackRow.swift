import SwiftUI
import Foundation

struct TrackRow: View {
    @EnvironmentObject private var player: AudioPlayer
    let track: Track
    let queue: [Track]

    var body: some View {
        Button {
            player.play(track, in: queue)
        } label: {
            HStack(spacing: 12) {
                AsyncArtwork(url: track.artworkURL, size: 52)

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.headline)
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
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                player.playNext(track)
            } label: {
                Label(
                    "Играть следующим",
                    systemImage: "text.line.first.and.arrowtriangle.forward"
                )
            }
        }
    }
}

extension TimeInterval {
    var formattedDuration: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(self)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
