import SwiftUI

private struct ControlFeedbackModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isActive: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 17.0, *), !reduceMotion {
            content.symbolEffect(.bounce, value: isActive)
        } else {
            content
        }
    }
}

extension View {
    func controlFeedback(isActive: Bool) -> some View {
        modifier(ControlFeedbackModifier(isActive: isActive))
    }
}
