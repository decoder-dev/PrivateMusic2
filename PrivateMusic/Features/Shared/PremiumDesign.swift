import SwiftUI
import UIKit
import UserNotifications

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
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: PremiumLayout.cardRadius,
            style: .continuous
        )

        if #available(iOS 26.0, *) {
            // Real Liquid Glass card surface. glassEffect(in:) already
            // constrains the shape, so no separate clipShape here (that
            // combination is a documented source of rendering artifacts).
            content
                .contentShape(shape)
                .glassEffect(
                    .regular.interactive(interactive),
                    in: shape
                )
                .shadow(
                    color: .black.opacity(interactive ? 0.07 : 0.04),
                    radius: interactive ? 14 : 9,
                    y: interactive ? 7 : 4
                )
        } else {
            content
                .background(
                    Color(uiColor: .secondarySystemBackground)
                        .opacity(0.82),
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

    static func success() {
        UINotificationFeedbackGenerator()
            .notificationOccurred(.success)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

enum DownloadNotifications {
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notifyDownloadComplete(title: String) {
        let content = UNMutableNotificationContent()
        content.title = L10n.text("Загрузка завершена")
        content.body = title
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "dl-done-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func notifyDownloadError(title: String) {
        let content = UNMutableNotificationContent()
        content.title = L10n.text("Ошибка загрузки")
        content.body = title
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "dl-err-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
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
