import SwiftUI
import UIKit

enum PremiumLayout {
    static let screenPadding: CGFloat = 16
    static let cardRadius: CGFloat = 22
    static let compactRadius: CGFloat = 16
    static let controlRadius: CGFloat = 14
    static let minimumTapTarget: CGFloat = 44

    static func artworkRadius(for size: CGFloat) -> CGFloat {
        min(cardRadius, max(8, size * 0.18))
    }
}

struct PremiumCardModifier: ViewModifier {
    @EnvironmentObject private var settings: AppSettings
    let interactive: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: PremiumLayout.cardRadius,
            style: .continuous
        )

        content
            .background(
                Color(uiColor: .secondarySystemBackground)
                    .opacity(settings.liquidGlassEnabled ? 0.72 : 0.96),
                in: shape
            )
            .overlay {
                shape.stroke(.primary.opacity(0.07), lineWidth: 0.75)
            }
            .clipShape(shape)
            .contentShape(shape)
            .shadow(
                color: .black.opacity(interactive ? 0.07 : 0.04),
                radius: interactive ? 14 : 9,
                y: interactive ? 7 : 4
            )
    }
}

struct PremiumPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(
                reduceMotion || !configuration.isPressed ? 1 : 0.975
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(
                reduceMotion
                    ? nil
                    : .spring(response: 0.22, dampingFraction: 0.82),
                value: configuration.isPressed
            )
    }
}

struct PremiumAppearModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(reduceMotion || appeared ? 1 : 0)
            .scaleEffect(reduceMotion || appeared ? 1 : 0.97)
            .offset(y: reduceMotion || appeared ? 0 : 8)
            .onAppear {
                guard !appeared else { return }
                if reduceMotion {
                    appeared = true
                } else {
                    withAnimation(
                        .spring(
                            response: 0.44,
                            dampingFraction: 0.86
                        )
                        .delay(delay)
                    ) {
                        appeared = true
                    }
                }
            }
    }
}

struct PremiumSectionHeader: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.text(title))
                .font(.title2.weight(.bold))
            if let subtitle {
                Text(L10n.text(subtitle))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

@MainActor
enum Haptics {
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func trackChange() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func open() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

extension View {
    func premiumCard(interactive: Bool = false) -> some View {
        modifier(PremiumCardModifier(interactive: interactive))
    }

    func premiumAppear(delay: Double = 0) -> some View {
        modifier(PremiumAppearModifier(delay: delay))
    }
}
