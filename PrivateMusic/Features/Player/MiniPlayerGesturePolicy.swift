import CoreGraphics
import Foundation

enum MiniPlayerGestureAction: Equatable, Sendable {
    case next
    case previous
    case openPlayer
}

/// Axis-aware swipe recognition for the compact mini player.
enum MiniPlayerGesturePolicy {
    static let minimumDistance: CGFloat = 18
    static let horizontalThreshold: CGFloat = 58
    static let verticalThreshold: CGFloat = 42
    static let horizontalParallaxFactor: CGFloat = 0.12
    static let verticalParallaxFactor: CGFloat = 0.08

    /// Chooses an action from the settled translation and the predicted end
    /// translation so fast flicks still register even when the finger lifts
    /// early. Returns `nil` for short or ambiguous drags.
    static func action(
        translation: CGSize,
        predictedEndTranslation: CGSize,
        minimumDistance: CGFloat = minimumDistance,
        horizontalThreshold: CGFloat = horizontalThreshold,
        verticalThreshold: CGFloat = verticalThreshold
    ) -> MiniPlayerGestureAction? {
        let effective = effectiveTranslation(
            translation: translation,
            predictedEndTranslation: predictedEndTranslation
        )
        let horizontal = abs(effective.width)
        let vertical = abs(effective.height)

        guard max(horizontal, vertical) >= minimumDistance else {
            return nil
        }

        if vertical > horizontal {
            guard effective.height <= -verticalThreshold else {
                return nil
            }
            return .openPlayer
        }

        if effective.width <= -horizontalThreshold {
            return .next
        }
        if effective.width >= horizontalThreshold {
            return .previous
        }
        return nil
    }

    /// Decorative drag offset applied while the finger is down. Always
    /// `.zero` when Reduce Motion is enabled.
    static func dragOffset(
        translation: CGSize,
        reduceMotion: Bool,
        horizontalFactor: CGFloat = horizontalParallaxFactor,
        verticalFactor: CGFloat = verticalParallaxFactor
    ) -> CGSize {
        guard !reduceMotion else { return .zero }
        return CGSize(
            width: translation.width * horizontalFactor,
            height: min(translation.height * verticalFactor, 0)
        )
    }

    /// Prefers the predicted end translation when it has travelled farther on
    /// either axis, which makes quick flicks reliable.
    static func effectiveTranslation(
        translation: CGSize,
        predictedEndTranslation: CGSize
    ) -> CGSize {
        let usePredictedWidth =
            abs(predictedEndTranslation.width) > abs(translation.width)
        let usePredictedHeight =
            abs(predictedEndTranslation.height) > abs(translation.height)
        return CGSize(
            width: usePredictedWidth
                ? predictedEndTranslation.width
                : translation.width,
            height: usePredictedHeight
                ? predictedEndTranslation.height
                : translation.height
        )
    }
}
