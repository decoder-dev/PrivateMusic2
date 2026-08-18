import SwiftUI
import UIKit
import UserNotifications

enum PremiumLayout {
    static let screenPadding: CGFloat = BubbleSpacing.l
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: PremiumLayout.cardRadius,
            style: .continuous
        )

        if #available(iOS 26.0, *), !reduceTransparency {
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
        VStack(alignment: .leading, spacing: BubbleSpacing.xs) {
            // Both labels need an explicit line budget and `fixedSize`.
            // Without it a wrapped title or subtitle is laid out in the
            // height of a single line, so the extra lines render over the
            // content underneath instead of pushing it down — the text
            // overlap seen across the mix screens, whose long localized
            // section names wrap on narrow phones and at larger text sizes.
            Text(L10n.text(title))
                .font(BubbleType.section)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(L10n.text(subtitle))
                    .font(BubbleType.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct AppGroupedSection<Content: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BubbleSpacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: BubbleSpacing.m) {
                PremiumSectionHeader(title, subtitle: subtitle)
                Spacer(minLength: 0)
                trailing()
            }
            AppGroupedSurface {
                content()
            }
        }
    }
}

struct AppGroupedSurface<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, BubbleSpacing.xs)
        .premiumCard()
    }
}

struct AppGroupedRow<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing
    var minHeight: CGFloat = 56

    init(
        minHeight: CGFloat = 56,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.leading = leading
        self.trailing = trailing
        self.minHeight = minHeight
    }

    var body: some View {
        HStack(spacing: BubbleSpacing.m) {
            leading()
            Spacer(minLength: BubbleSpacing.s)
            trailing()
        }
        .padding(.horizontal, BubbleSpacing.m)
        .frame(minHeight: minHeight)
        .contentShape(Rectangle())
    }
}

struct AppInlineMessageCard: View {
    @Environment(AppSettings.self) private var settings
    let message: String
    let systemImage: String
    var tint: Color = .orange
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: BubbleSpacing.s) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(message)
                .font(BubbleType.metadata)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: BubbleSpacing.xs)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .padding(.horizontal, BubbleSpacing.l)
        .padding(.vertical, BubbleSpacing.m)
        .background(
            tint.opacity(settings.theme == .dark ? 0.12 : 0.09),
            in: RoundedRectangle(
                cornerRadius: BubbleRadius.compact,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: BubbleRadius.compact,
                style: .continuous
            )
            .stroke(
                tint.opacity(settings.theme == .dark ? 0.28 : 0.2),
                lineWidth: 0.7
            )
        }
    }
}

struct AppStatusPanel: View {
    @Environment(AppSettings.self) private var settings
    let title: String
    let systemImage: String
    let description: String
    var titleIsLocalizedKey = true
    var descriptionIsLocalizedKey = true
    var actionTitle: String? = nil
    var actionTitleIsLocalizedKey = true
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: BubbleSpacing.m) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(settings.theme.accent)
                .accessibilityHidden(true)
            Text(titleIsLocalizedKey ? L10n.text(title) : title)
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(
                descriptionIsLocalizedKey
                    ? L10n.text(description)
                    : description
            )
                .font(BubbleType.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(
                    actionTitleIsLocalizedKey
                        ? L10n.text(actionTitle)
                        : actionTitle,
                    action: action
                )
                    .font(.system(size: 15, weight: .semibold))
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(BubbleSpacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
enum Haptics {
    /// Kept in sync with `AppSettings.hapticsEnabled` so every call site
    /// stays gated without threading the setting through each fire site.
    static var isEnabled = true

    static func selection() {
        guard isEnabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func trackChange() {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func open() {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func success() {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator()
            .notificationOccurred(.success)
    }

    static func error() {
        guard isEnabled else { return }
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
        content.title = L10n.text("download_complete")
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
        content.title = L10n.text("download_failed_2")
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
