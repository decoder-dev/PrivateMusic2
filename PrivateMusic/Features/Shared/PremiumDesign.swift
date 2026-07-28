import SwiftUI
import UIKit

enum PremiumLayout {
    static let screenPadding: CGFloat = 16
    static let cardRadius: CGFloat = 22
    static let compactRadius: CGFloat = 16
    static let minimumTapTarget: CGFloat = 44
}

struct PremiumCardModifier: ViewModifier {
    @EnvironmentObject private var settings: AppSettings
    let interactive: Bool

    func body(content: Content) -> some View {
        content
            .background(
                Color(uiColor: .secondarySystemBackground)
                    .opacity(settings.liquidGlassEnabled ? 0.72 : 0.96),
                in: RoundedRectangle(
                    cornerRadius: PremiumLayout.cardRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: PremiumLayout.cardRadius,
                    style: .continuous
                )
                .stroke(.primary.opacity(0.07), lineWidth: 0.75)
            }
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

struct PremiumSectionHeader: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title2.weight(.bold))
            if let subtitle {
                Text(subtitle)
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
}
