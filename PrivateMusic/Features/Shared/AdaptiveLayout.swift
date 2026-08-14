import CoreGraphics

/// Width-based layout tokens shared by home rails, mix shelves, and the
/// library. Values are pure functions of container width so they can be
/// unit-tested without a view tree.
///
/// Compact phone (≤350) uses tighter padding. Regular phones keep the
/// existing 16pt gutters. iPad / regular width (≥700) opens the margins
/// and stops shelf cards from being capped at the ~140pt phone maximum.
enum AdaptiveLayout {
    static let compactPhoneWidth: CGFloat = 350
    static let largePhoneWidth: CGFloat = 500
    static let regularWidthMinimum: CGFloat = 700
    static let compactPhonePadding: CGFloat = 14
    static let regularPhonePadding: CGFloat = 16
    static let regularWidthPadding: CGFloat = 24
    static let regularCardWidthFraction: CGFloat = 0.18
    static let regularCardWidthCap: CGFloat = 220

    static func isRegularWidth(_ width: CGFloat) -> Bool {
        width >= regularWidthMinimum
    }

    /// 14 compact phone, 16 regular phone, 24+ iPad.
    static func horizontalPadding(for width: CGFloat) -> CGFloat {
        if isRegularWidth(width) {
            return regularWidthPadding
        }
        return width <= compactPhoneWidth
            ? compactPhonePadding
            : regularPhonePadding
    }

    /// 2 phone, 3 large phone / landscape, 4 iPad.
    static func columnCount(for width: CGFloat) -> Int {
        if isRegularWidth(width) {
            return 4
        }
        if width >= largePhoneWidth {
            return 3
        }
        return 2
    }

    /// Phone cards keep their existing fraction + compact cap. On width
    /// ≥700 the card is ~18% of the container, never below `compactMax`,
    /// and capped around 220 so iPad rails can grow past ~140pt.
    static func shelfCardWidth(
        for width: CGFloat,
        compactMax: CGFloat,
        regularMax: CGFloat,
        fraction: CGFloat = 0.35,
        compactMin: CGFloat = 112
    ) -> CGFloat {
        if isRegularWidth(width) {
            return min(
                max(width * regularCardWidthFraction, compactMax),
                regularMax
            )
        }
        return min(max(width * fraction, compactMin), compactMax)
    }
}
