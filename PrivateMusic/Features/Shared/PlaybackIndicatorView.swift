import SwiftUI

/// Four still bars while playing, a pause glyph otherwise. It does not
/// move: an equalizer that dances on every visible row costs frames and
/// battery for no information the play state does not already give.
struct PlaybackIndicatorView: View {
    let isPlaying: Bool
    var color: Color?
    @Environment(AppSettings.self) private var settings

    private static let barHeights: [CGFloat] = [0.46, 0.88, 0.66, 0.38]

    private var resolvedColor: Color {
        color ?? settings.accent
    }

    var body: some View {
        Group {
            if isPlaying {
                bars
            } else {
                Image(systemName: "pause.fill")
            }
        }
        .foregroundStyle(resolvedColor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            L10n.text(isPlaying ? "current_track" : "paused")
        )
    }

    private var bars: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Self.barHeights.indices, id: \.self) { bar in
                Capsule()
                    .frame(width: 3, height: 16 * Self.barHeights[bar])
            }
        }
        .frame(width: 18, height: 16)
    }
}
