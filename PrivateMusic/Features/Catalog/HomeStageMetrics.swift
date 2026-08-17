import CoreGraphics

/// Geometry for the Home stage, resolved up front from the container
/// width the same way the library shelves and the player do it. Keeping it
/// out of the view body means the sizes can be checked directly, and that
/// the stage cannot silently grow past a screen on a small phone.
enum HomeStageMetrics {
    /// Bounded so the artist name stays huge on a Pro Max without
    /// overflowing an SE, where the container is barely 375 pt wide.
    static func artistFontSize(for width: CGFloat) -> CGFloat {
        clamp(width * 0.125, minimum: 32, maximum: 48)
    }

    static func artworkSize(for width: CGFloat) -> CGFloat {
        clamp(width * 0.38, minimum: 108, maximum: 152)
    }

    static func controlHeight(for width: CGFloat) -> CGFloat {
        clamp(width * 0.145, minimum: 48, maximum: 58)
    }

    /// The largest bubble. The rest are derived from it so the rail keeps
    /// its uneven, hand-placed rhythm without four more constants.
    static func bubbleSize(for width: CGFloat) -> CGFloat {
        clamp(width * 0.40, minimum: 108, maximum: 156)
    }

    static func bubbleSize(for width: CGFloat, index: Int) -> CGFloat {
        let base = bubbleSize(for: width)
        // Repeating 1 / 0.86 / 0.94 / 0.8 keeps neighbours from ever
        // matching, which is what makes the row read as bubbles rather
        // than as a carousel of circles.
        let scales: [CGFloat] = [1, 0.86, 0.94, 0.8]
        return (base * scales[index % scales.count]).rounded()
    }

    static func avatarSize(for width: CGFloat) -> CGFloat {
        clamp(bubbleSize(for: width) * 0.32, minimum: 36, maximum: 52)
    }

    /// Deliberately shorter than the tallest bubble plus its avatar: the
    /// row is bottom-aligned inside a window that ends above the bubbles'
    /// baseline, so every circle is cut by the same horizontal line no
    /// matter its diameter. That shared cut is what reads as shapes
    /// rising from the edge rather than as a carousel of circles.
    static func railHeight(for width: CGFloat) -> CGFloat {
        (avatarSize(for: width) / 2 + bubbleSize(for: width) * 0.74)
            .rounded()
    }

    /// Room above the circles for the avatar that straddles the rim.
    static func avatarOverhang(for width: CGFloat) -> CGFloat {
        (avatarSize(for: width) / 2).rounded()
    }

    /// How far the blurred artwork reaches before it has fully dissolved
    /// into the app background the shelves sit on.
    static let atmosphereFadeStart: CGFloat = 0.55

    private static func clamp(
        _ value: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        min(max(value, minimum), maximum)
    }
}

/// The fixed gaps `HomeStageView` stacks between its rows, named once so
/// the height check measures what the view actually builds instead of a
/// number copied into the test.
enum HomeStageViewPadding {
    static let chipHeight: CGFloat = 32
    static let belowChip: CGFloat = 20
    static let belowHeadline: CGFloat = 18
    static let belowArtwork: CGFloat = 20
    static let belowTransport: CGFloat = 22

    static var total: CGFloat {
        chipHeight + belowChip + belowHeadline + belowArtwork
            + belowTransport
    }
}
