import SwiftUI

/// Which screens must reserve space for the mini player themselves.
///
/// The legacy overlay dock already does this in `tabScreen`. iOS 26 system
/// tabs put the mini player in `tabViewBottomAccessory`, which does not
/// reliably inset `NavigationStack` destinations or GeometryReader-backed
/// scroll views — Home's last row and album track lists sat underneath it.
enum PlaybackChromePolicy {
    static func needsExplicitMiniPlayerClearance(
        isIOS26OrLater: Bool,
        classicChrome: Bool
    ) -> Bool {
        isIOS26OrLater && !classicChrome
    }
}

private struct PlaybackDockReservesContentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when a parent already reserved dock + mini-player height
    /// (`tabScreen` overlay or the regular-width playback bar).
    var playbackDockReservesContent: Bool {
        get { self[PlaybackDockReservesContentKey.self] }
        set { self[PlaybackDockReservesContentKey.self] = newValue }
    }
}

/// Lifts scrollable content so the last row sits above the mini player,
/// with the same clearance `BottomAccessoryMetrics` uses for the dock.
struct MiniPlayerContentClearance: ViewModifier {
    @Environment(PlaybackHighlightModel.self) private var highlight
    @Environment(\.playbackDockReservesContent) private var playbackDockReservesContent
    /// Pushed screens (album, playlist) must lift even when the tab root's
    /// dock reservation does not reach the destination.
    var includingWhenDockReservesSpace: Bool

    func body(content: Content) -> some View {
        let isEnabled = includingWhenDockReservesSpace
            || !playbackDockReservesContent
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear
                .frame(
                    height: isEnabled
                        ? BottomAccessoryMetrics.miniPlayerClearance(
                            hasMiniPlayer: highlight.currentTrackID != nil
                        )
                        : 0
                )
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// Reserve the mini-player strip at the bottom of a scroll view or list.
    /// Tab roots omit `includingWhenDockReservesSpace` so the legacy overlay
    /// dock is not padded twice. Pushed screens pass `true`.
    func clearsMiniPlayer(
        includingWhenDockReservesSpace: Bool = false
    ) -> some View {
        modifier(
            MiniPlayerContentClearance(
                includingWhenDockReservesSpace: includingWhenDockReservesSpace
            )
        )
    }
}
