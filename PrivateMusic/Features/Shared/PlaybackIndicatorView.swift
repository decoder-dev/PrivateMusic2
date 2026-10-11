import SwiftUI

struct PlaybackIndicatorView: View {
    let isPlaying: Bool
    var color: Color?
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var resolvedColor: Color {
        color ?? settings.accent
    }

    var body: some View {
        Group {
            if isPlaying {
                if !reduceMotion && scenePhase == .active && !ProcessInfo.processInfo.isLowPowerModeEnabled {
                    TimelineView(.animation(minimumInterval: 0.12)) { context in
                        bars(elapsed: context.date.timeIntervalSinceReferenceDate, animated: true)
                            .animation(.linear(duration: 0.12), value: context.date)
                    }
                } else {
                    bars(elapsed: 0, animated: false)
                }
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

    private func bars(elapsed: TimeInterval, animated: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { bar in
                Capsule()
                    .frame(width: 3, height: CGFloat(16 * PlaybackIndicatorMotion.heightFraction(
                        bar: bar, elapsed: elapsed, animated: animated
                    )))
            }
        }
        .frame(width: 18, height: 16)
    }
}
