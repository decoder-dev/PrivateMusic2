import Foundation

/// Display mode for the system tab-bar bottom accessory on iOS 26.0+.
enum MiniPlayerAccessoryMode: Equatable, Sendable {
    case expanded
    case inline
}

/// What the accessory should render for a given player + placement state.
enum MiniPlayerAccessoryPresentation: Equatable, Sendable {
    case hidden
    case expanded
    case inline
}

/// Pure layout decisions for the system mini-player accessory. Mapping from
/// `TabViewBottomAccessoryPlacement` stays in the SwiftUI layer so unit tests
/// never need SDK-only placement values.
enum MiniPlayerAccessoryPolicy {
    static func presentation(
        hasCurrentTrack: Bool,
        mode: MiniPlayerAccessoryMode
    ) -> MiniPlayerAccessoryPresentation {
        guard hasCurrentTrack else { return .hidden }
        switch mode {
        case .expanded: return .expanded
        case .inline: return .inline
        }
    }

    static func shouldShowAccessory(hasCurrentTrack: Bool) -> Bool {
        hasCurrentTrack
    }

    static func showsArtist(_ mode: MiniPlayerAccessoryMode) -> Bool {
        mode == .expanded
    }

    static func showsNextButton(_ mode: MiniPlayerAccessoryMode) -> Bool {
        mode == .expanded
    }

    static func showsPreviousButton(_ mode: MiniPlayerAccessoryMode) -> Bool {
        // Expanded glass pill exposes both skips; inline keeps previous only
        // (space is tight — next stays swipe / a11y).
        true
    }

    static func showsProgress(_ mode: MiniPlayerAccessoryMode) -> Bool {
        mode == .expanded
    }

    /// System `tabViewBottomAccessory` already draws Liquid Glass for both
    /// placements. Legacy floating dock opts into its own plate via
    /// `MiniPlayerView(showsOwnGlassChrome: true)`.
    static func showsOwnGlassChrome(_ mode: MiniPlayerAccessoryMode) -> Bool {
        false
    }

    static func showsBufferingIndicator(isBuffering: Bool) -> Bool {
        isBuffering
    }
}
