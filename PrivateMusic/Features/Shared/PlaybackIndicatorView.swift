import SwiftUI

struct PlaybackIndicatorView: View {
    let isPlaying: Bool
    var color: Color?
    @Environment(AppSettings.self) private var settings

    private var resolvedColor: Color {
        color ?? settings.theme.accent
    }

    var body: some View {
        Group {
            if isPlaying {
                if #available(iOS 17.0, *) {
                    Image(systemName: "waveform")
                        .symbolEffect(
                            .variableColor.iterative,
                            options: .repeating
                        )
                } else {
                    Image(systemName: "waveform")
                }
            } else {
                Image(systemName: "pause.fill")
            }
        }
        .foregroundStyle(resolvedColor)
        .accessibilityLabel(
            L10n.text(isPlaying ? "current_track" : "paused")
        )
    }
}
