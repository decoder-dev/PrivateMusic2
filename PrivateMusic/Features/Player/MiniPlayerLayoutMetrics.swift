import CoreGraphics
import Foundation

/// Layout constants for the Apple Music–style compact mini player.
enum MiniPlayerLayoutMetrics {
    static let artworkSize: CGFloat = 42
    /// Squircle, matching BubbleShapeLanguage.media at this size, so
    /// artwork curves identically in the dock, the stage and the shelves —
    /// computed from the same formula rather than a radius hand-tuned to
    /// whatever `artworkSize` used to be.
    static let artworkCornerRadius: CGFloat = BubbleRadius.artwork(
        for: artworkSize
    )
    static let artworkShadowRadius: CGFloat = 3
    static let artworkShadowY: CGFloat = 1
    static let inlineArtworkSize: CGFloat = 28
    static let inlineArtworkCornerRadius: CGFloat = 5
    static let tapTarget: CGFloat = 44
    static let progressHeight: CGFloat = 2
    /// The progress line used to sit flush on the container's bottom edge,
    /// where both the border stroke and the 16 pt corner curve cross it: it
    /// read as a stray blue line laid over the card instead of part of it.
    /// The side inset clears the corners, and the top spacing pays for the
    /// bottom one so the dock does not get any taller.
    static let progressTopSpacing: CGFloat = 3
    static let progressBottomInset: CGFloat = 4
    static let progressSideInset: CGFloat = 18
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 7
    static let inlineHorizontalPadding: CGFloat = 8
    static let inlineVerticalPadding: CGFloat = 4
    static let contentSpacing: CGFloat = 12
    static let inlineContentSpacing: CGFloat = 8
    static let controlSpacing: CGFloat = 2
    /// 56–60 pt visual height: the compact bar Apple Music itself uses,
    /// not a second, shorter player.
    static let minHeight: CGFloat = 58
    static let cornerRadius: CGFloat = 16
    static let containerShadowRadius: CGFloat = 8
    static let containerShadowY: CGFloat = 3
    static let glassTintOpacity: CGFloat = 0.03
    static let trackCrossfadeDuration: TimeInterval = 0.32
    static let reduceMotionCrossfadeDuration: TimeInterval = 0.08
}
