import SwiftUI

/// The Human Interface Guidelines ask for at least 44×44 points of
/// touchable area for every control. Some controls are deliberately drawn
/// smaller than that — a play chip tucked into the corner of a piece of
/// artwork reads as a chip, not as a button, and growing the circle would
/// change the composition.
///
/// The way out is that what a finger hits and what an eye sees do not have
/// to be the same size. These helpers grow only the first one.
enum HitTargetPolicy {
    static let minimum = PremiumLayout.minimumTapTarget

    /// How far past its drawn edge a control has to accept a touch to
    /// reach the minimum. Zero once the control is already big enough —
    /// the hit area is never pulled back in.
    static func outset(forVisualSize visualSize: CGFloat) -> CGFloat {
        max(0, (minimum - visualSize) / 2)
    }
}

extension View {
    /// Accepts touches up to the HIG minimum around a control drawn
    /// smaller than that, **without changing the layout**: the view still
    /// occupies exactly the space it did, so nothing around it shifts.
    ///
    /// Apply it to the drawn shape, inside the button's label, after the
    /// frame and background that give the control its size.
    func minimumHitTarget(visualSize: CGFloat) -> some View {
        minimumHitTarget(visualSize: visualSize, in: Circle())
    }

    func minimumHitTarget<S: InsettableShape>(
        visualSize: CGFloat,
        in shape: S
    ) -> some View {
        contentShape(
            shape.inset(
                by: -HitTargetPolicy.outset(forVisualSize: visualSize)
            )
        )
    }
}
