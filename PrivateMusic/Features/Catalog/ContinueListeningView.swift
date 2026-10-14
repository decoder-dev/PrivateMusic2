import SwiftUI

/// Playback observation is confined to this small card, not the Home tree.
struct ContinueListeningView: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if let track = player.currentTrack, !player.isPlaying {
            Button { player.resume() } label: {
                HStack(spacing: BubbleSpacing.m) {
                    AsyncArtwork(url: track.artworkURL, size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("home.continue"))
                            .font(.caption.weight(.semibold)).foregroundStyle(settings.accent)
                        Text(track.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                        Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text(L10n.format("home.continue.position", position, L10n.trackCount(player.queue.count)))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "play.fill").foregroundStyle(settings.accent)
                }
                .padding(BubbleSpacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: PremiumLayout.cardRadius))
                .contentShape(Rectangle())
            }
            .buttonStyle(PremiumPressStyle())
            .accessibilityElement(children: .combine)
        }
    }

    private var position: String {
        let seconds = Int(player.elapsedTime.isFinite ? max(0, min(player.elapsedTime, 1_000_000)) : 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
