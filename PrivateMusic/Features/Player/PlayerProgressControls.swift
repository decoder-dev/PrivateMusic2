import SwiftUI
import UIKit

/// Scrubber + elapsed/remaining labels isolated from `PlayerView` so
/// transport ticks rebuild only this subtree, not artwork and controls.
struct PlayerProgressControls: View {
    @Environment(PlaybackProgressModel.self) private var progress
    let duration: TimeInterval
    let foreground: Color
    let secondary: Color
    let onSeek: (TimeInterval) -> Void

    @State private var scrubPosition: TimeInterval?

    private var displayedElapsed: TimeInterval {
        PlayerProgressPolicy.displayedElapsed(
            scrubPosition: scrubPosition,
            elapsedTime: progress.elapsedTime
        )
    }

    private var remaining: TimeInterval {
        PlayerProgressPolicy.remainingTime(
            elapsed: displayedElapsed,
            duration: duration
        )
    }

    private var isScrubbing: Bool { scrubPosition != nil }

    var body: some View {
        VStack(spacing: 3) {
            PlayerCompactSlider(
                value: Binding(
                    get: { displayedElapsed },
                    set: { scrubPosition = $0 }
                ),
                range: PlayerProgressPolicy.sliderRange(duration: duration),
                tintColor: UIColor(foreground),
                onEditingBegan: {
                    scrubPosition = progress.elapsedTime
                },
                onCommit: commitScrubbing
            )
            .frame(height: PlayerProgressPolicy.sliderTrackHeight)
            .accessibilityLabel(L10n.text("playback_position"))
            .accessibilityValue(
                "\(displayedElapsed.formattedDuration) / "
                    + duration.formattedDuration
            )

            HStack {
                Text(displayedElapsed.formattedDuration)
                Spacer()
                Text("-\(remaining.formattedDuration)")
            }
            .font(
                .system(
                    size: PlayerProgressPolicy.timeLabelFontSize,
                    weight: isScrubbing ? .semibold : .medium
                )
                .monospacedDigit()
            )
            .foregroundStyle(
                isScrubbing ? foreground : secondary
            )
            .opacity(isScrubbing ? 1 : 0.92)
            .frame(height: PlayerProgressPolicy.timeRowHeight)
        }
    }

    private func commitScrubbing(_ position: TimeInterval) {
        onSeek(position)
        scrubPosition = nil
    }
}

// MARK: - UIKit slider

private final class PlayerTappableSlider: UISlider {
    override func beginTracking(
        _ touch: UITouch,
        with event: UIEvent?
    ) -> Bool {
        let point = touch.location(in: self)
        let track = trackRect(forBounds: bounds)
        let span = max(track.width, 1)
        let percent = min(max((point.x - track.minX) / span, 0), 1)
        let next = minimumValue + Float(percent) * (maximumValue - minimumValue)
        setValue(next, animated: false)
        sendActions(for: .valueChanged)
        return super.beginTracking(touch, with: event)
    }
}

private struct PlayerCompactSlider: UIViewRepresentable {
    @Binding var value: TimeInterval
    let range: ClosedRange<TimeInterval>
    let tintColor: UIColor
    let onEditingBegan: () -> Void
    let onCommit: (TimeInterval) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UISlider {
        let slider = PlayerTappableSlider(frame: .zero)
        slider.isContinuous = true
        configureColors(slider, coordinator: context.coordinator)
        slider.addTarget(
            context.coordinator,
            action: #selector(Coordinator.valueChanged(_:)),
            for: .valueChanged
        )
        slider.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingBegan(_:)),
            for: .touchDown
        )
        slider.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingEnded(_:)),
            for: [.touchUpInside, .touchUpOutside, .touchCancel]
        )
        return slider
    }

    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.cachedTintColor != tintColor {
            configureColors(slider, coordinator: context.coordinator)
        }
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(max(range.upperBound, range.lowerBound + 1))
        guard !slider.isTracking else { return }
        let safeValue = value.isFinite ? value : range.lowerBound
        let next = Float(min(max(safeValue, range.lowerBound), range.upperBound))
        if abs(slider.value - next) >= 0.05 {
            slider.setValue(next, animated: false)
        }
    }

    private func configureColors(
        _ slider: UISlider,
        coordinator: Coordinator
    ) {
        let diameter = PlayerProgressPolicy.thumbDiameter
        slider.minimumTrackTintColor = tintColor
        slider.maximumTrackTintColor = tintColor.withAlphaComponent(0.18)
        let thumb = coordinator.thumb(diameter: diameter, tint: tintColor)
        slider.setThumbImage(thumb, for: .normal)
        slider.setThumbImage(thumb, for: .highlighted)
        coordinator.cachedTintColor = tintColor
    }

    final class Coordinator: NSObject {
        var parent: PlayerCompactSlider
        var cachedTintColor: UIColor?
        private var thumbCache: [String: UIImage] = [:]

        init(parent: PlayerCompactSlider) {
            self.parent = parent
        }

        func thumb(diameter: CGFloat, tint: UIColor) -> UIImage {
            let key = "\(diameter)-\(tint.hash)"
            if let cached = thumbCache[key] {
                return cached
            }
            let size = CGSize(width: diameter, height: diameter)
            let image = UIGraphicsImageRenderer(size: size).image { context in
                context.cgContext.setShadow(
                    offset: CGSize(width: 0, height: 1),
                    blur: 3,
                    color: UIColor.black.withAlphaComponent(0.28).cgColor
                )
                tint.setFill()
                UIBezierPath(
                    ovalIn: CGRect(origin: .zero, size: size).insetBy(
                        dx: 0.5,
                        dy: 0.5
                    )
                )
                .fill()
            }
            thumbCache[key] = image
            return image
        }

        @objc
        func valueChanged(_ slider: UISlider) {
            if !slider.isTracking {
                parent.onEditingBegan()
            }
            parent.value = TimeInterval(slider.value)
            if !slider.isTracking {
                parent.onCommit(TimeInterval(slider.value))
            }
        }

        @objc
        func editingBegan(_ slider: UISlider) {
            parent.onEditingBegan()
        }

        @objc
        func editingEnded(_ slider: UISlider) {
            parent.value = TimeInterval(slider.value)
            parent.onCommit(TimeInterval(slider.value))
        }
    }
}
