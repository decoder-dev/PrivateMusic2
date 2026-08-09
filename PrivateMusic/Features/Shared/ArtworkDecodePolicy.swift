import CoreGraphics
import Foundation

/// Keeps decoded artwork near on-screen pixels so catalog / mix shelves do
/// not fill `ArtworkImageCache` with 1200² bitmaps for 48–150 pt tiles.
enum ArtworkDecodePolicy {
    static let minimumPixelSize: CGFloat = 128

    static func maxPixelSize(
        displayPoints: CGFloat,
        scale: CGFloat
    ) -> CGFloat {
        let safeScale = scale.isFinite ? max(scale, 1) : 1
        let safePoints = displayPoints.isFinite ? max(displayPoints, 1) : 1
        return max(safePoints * safeScale, minimumPixelSize)
    }

    static func maxPixelSize(
        width: CGFloat,
        height: CGFloat,
        scale: CGFloat
    ) -> CGFloat {
        maxPixelSize(
            displayPoints: max(width, height),
            scale: scale
        )
    }
}
