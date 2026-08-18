import CoreGraphics
import SwiftUI

/// Vertical breathing room for queue rows. The default List inset left
/// upcoming tracks stacked on each other — users called it «налеплены».
enum QueueRowMetrics {
    static let verticalInset: CGFloat = BubbleSpacing.s
    static let horizontalInset: CGFloat = BubbleSpacing.l

    /// Track row content is ~48 pt artwork plus two text lines; add inset
    /// so rows do not read as one continuous slab.
    static let minRowHeight: CGFloat = 64

    static var listRowInsets: EdgeInsets {
        EdgeInsets(
            top: verticalInset,
            leading: horizontalInset,
            bottom: verticalInset,
            trailing: horizontalInset
        )
    }
}
