import SwiftUI

struct PlaybackIndicatorView: View {
    let isPlaying: Bool
    var color: Color = .accentColor

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
        .foregroundStyle(color)
        .accessibilityLabel(
            L10n.text(isPlaying ? "Сейчас играет" : "На паузе")
        )
    }
}
