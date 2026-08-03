import AVFoundation
import MediaPlayer
import SwiftUI

/// Observes `AVAudioSession.outputVolume` for UI chrome next to the
/// system volume slider (icon / percent). The slider itself is an
/// `MPVolumeView` so it drives hardware volume like Apple Music.
@MainActor
final class SystemVolumeObserver: ObservableObject {
    @Published private(set) var volume: Float

    private var observation: NSKeyValueObservation?

    init(session: AVAudioSession = .sharedInstance()) {
        volume = session.outputVolume
        observation = session.observe(
            \.outputVolume,
            options: [.new]
        ) { [weak self] session, _ in
            let value = session.outputVolume
            Task { @MainActor in
                self?.volume = value
            }
        }
    }

    deinit {
        observation?.invalidate()
    }
}

/// Hardware volume control. Hides the route button — AirPlay already has
/// its own picker in the player chrome.
struct SystemVolumeSlider: UIViewRepresentable {
    var tintColor: UIColor = .systemBlue

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsVolumeSlider = true
        hideRouteButton(in: view)
        applyTint(view)
        view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        view.setContentCompressionResistancePriority(
            .defaultHigh,
            for: .vertical
        )
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        hideRouteButton(in: view)
        applyTint(view)
    }

    private func hideRouteButton(in view: MPVolumeView) {
        view.subviews
            .compactMap { $0 as? UIButton }
            .forEach { $0.isHidden = true }
    }

    private func applyTint(_ view: MPVolumeView) {
        view.tintColor = tintColor
        if let slider = view.subviews.compactMap({ $0 as? UISlider }).first {
            slider.tintColor = tintColor
            slider.minimumTrackTintColor = tintColor
        }
    }
}
