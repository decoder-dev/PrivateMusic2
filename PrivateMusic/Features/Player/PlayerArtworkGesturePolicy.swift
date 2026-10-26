import CoreGraphics

enum PlayerArtworkGestureAction: Equatable {
    case next, previous, queue, dismiss
}

enum PlayerArtworkGesturePolicy {
    static func action(translation: CGSize, predictedEndTranslation: CGSize) -> PlayerArtworkGestureAction? {
        let horizontal = translation.width
        let vertical = translation.height
        if abs(horizontal) >= 24, abs(horizontal) > abs(vertical) * 1.25 {
            let predicted = predictedEndTranslation.width
            let isFlick = horizontal * predicted > 0 && abs(predicted) >= 90
            guard abs(horizontal) >= 58 || isFlick else { return nil }
            return horizontal < 0 ? .next : .previous
        }
        if vertical < -52, abs(vertical) > abs(horizontal) * 1.25 {
            return .queue
        }
        if PlayerDismissGesturePolicy.shouldDismiss(
            translation: translation, predictedEndTranslation: predictedEndTranslation
        ) { return .dismiss }
        return nil
    }
}
