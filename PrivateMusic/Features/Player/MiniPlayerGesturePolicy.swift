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
    static let axisDominanceRatio: CGFloat = 1.2
    static let horizontalParallaxFactor: CGFloat = 0.12
    static let verticalParallaxFactor: CGFloat = 0.08

    /// Chooses an action from the settled translation and the predicted end
    /// translation so fast flicks still register even when the finger lifts
    /// early. Returns `nil` for short, downward, or ambiguous diagonal drags.
    static func action(
        translation: CGSize,
        predictedEndTranslation: CGSize,
        minimumDistance: CGFloat = minimumDistance,
        horizontalThreshold: CGFloat = horizontalThreshold,
        verticalThreshold: CGFloat = verticalThreshold,
        axisDominanceRatio: CGFloat = axisDominanceRatio
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

        if vertical >= horizontal * axisDominanceRatio {
            guard effective.height <= -verticalThreshold else {
                return nil
            }
            return .openPlayer
        }

        if horizontal >= vertical * axisDominanceRatio {
            if effective.width <= -horizontalThreshold {
                return .next
            }
            if effective.width >= horizontalThreshold {
                return .previous
            }
            return nil
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

    /// Picks one complete vector — never mixes X from one sample with Y from
    /// another — preferring the predicted end when its Euclidean length is
    /// strictly greater than the settled translation.
    static func effectiveTranslation(
        translation: CGSize,
        predictedEndTranslation: CGSize
    ) -> CGSize {
        let settled = hypot(translation.width, translation.height)
        let predicted = hypot(
            predictedEndTranslation.width,
            predictedEndTranslation.height
        )
        if predicted > settled {
            return predictedEndTranslation
        }
        return translation
    }
}
