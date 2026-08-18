import SwiftUI

// MARK: - Surface

/// The material a bubble is made of. Glass bubbles borrow the app's
/// existing `adaptiveGlass`, so Liquid Glass on iOS 26 and the classic
/// switch both keep working without a second implementation.
enum BubbleFill {
    /// Chrome: navigation, chips, status, floating controls.
    case glass(tint: Color?, interactive: Bool)
    /// A musical context: opaque, tinted by role or artwork.
    case solid(BubbleColorComponents)

    /// Plain chrome, no tint, non-interactive — by far the common case.
    static let chrome = BubbleFill.glass(tint: nil, interactive: false)
}

/// One surface for every bubble in the app. Circles and squircles differ
/// only by the shape passed in, so they are the same component rather
/// than two that drift apart.
struct BubbleSurface<S: Shape, Content: View>: View {
    let shape: S
    var fill: BubbleFill = .chrome
    var elevation: BubbleElevation = .resting
    @ViewBuilder var content: () -> Content

    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        switch fill {
        case let .glass(tint, interactive):
            content()
                .adaptiveGlass(
                    in: shape,
                    interactive: interactive,
                    tint: tint
                )
                .shadow(
                    color: .black.opacity(elevation.shadowOpacity(dark: isDark)),
                    radius: elevation.shadowRadius,
                    y: elevation.shadowOffset
                )
        case let .solid(components):
            content()
                .background(components.color, in: shape)
                .overlay {
                    let increased = colorSchemeContrast == .increased
                    shape.stroke(
                        Color.primary.opacity(
                            ContrastPolicy.strokeOpacity(
                                increased: increased,
                                reduceTransparency: reduceTransparency,
                                base: 0.10
                            )
                        ),
                        lineWidth: ContrastPolicy.strokeWidth(increased: increased)
                    )
                }
                .contentShape(shape)
                .shadow(
                    color: .black.opacity(elevation.shadowOpacity(dark: isDark)),
                    radius: elevation.shadowRadius,
                    y: elevation.shadowOffset
                )
        }
    }

    private var isDark: Bool { settings.theme == .dark }
}

/// Depth, in three steps. Shadows are softer in dark mode, where a heavy
/// one reads as grime rather than lift.
enum BubbleElevation {
    case flat
    case resting
    case floating

    var shadowRadius: CGFloat {
        switch self {
        case .flat: 0
        case .resting: 10
        case .floating: 18
        }
    }

    var shadowOffset: CGFloat {
        switch self {
        case .flat: 0
        case .resting: 4
        case .floating: 8
        }
    }

    func shadowOpacity(dark: Bool) -> Double {
        switch self {
        case .flat: 0
        case .resting: dark ? 0.20 : 0.10
        case .floating: dark ? 0.30 : 0.16
        }
    }
}

// MARK: - Action bubble

/// A verb: play, like, shuffle, more. Always circular, always at least
/// 44×44, always labelled for VoiceOver.
struct BubbleIconButton: View {
    let systemImage: String
    var size: CGFloat = BubbleMetrics.minimumTapTarget
    var role: BubbleRole = .neutral
    var isProminent = false
    var isActive = false
    var isEnabled = true
    let accessibilityLabel: String
    var accessibilityValue: String?
    let action: () -> Void

    @Environment(AppSettings.self) private var settings

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(BubblePressStyle())
        .disabled(!isEnabled)
        .background {
            if isProminent {
                Circle().fill(BubblePalette.color(role))
            }
        }
        .modifier(
            BubbleGlassIfNeeded(isGlass: !isProminent, isActive: isActive)
        )
        .opacity(isEnabled ? 1 : 0.4)
        .frame(
            minWidth: BubbleMetrics.minimumTapTarget,
            minHeight: BubbleMetrics.minimumTapTarget
        )
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue ?? "")
    }

    private var glyphSize: CGFloat { (size * 0.36).rounded() }

    /// Active state reads through colour, not through a filled ball: an
    /// accent glyph on a barely-tinted surface is the "restrained accent"
    /// the heart needs — a solid fill at this size reads as a dominant
    /// blue disc rather than a status.
    private var foreground: Color {
        if isProminent { return .white }
        if isActive { return settings.theme.accent }
        return .primary
    }
}

/// Split out so `BubbleIconButton` can pick glass or a solid fill without
/// duplicating the whole button body in an `if`.
private struct BubbleGlassIfNeeded: ViewModifier {
    let isGlass: Bool
    let isActive: Bool
    @Environment(AppSettings.self) private var settings

    @ViewBuilder
    func body(content: Content) -> some View {
        if isGlass {
            content.adaptiveGlass(
                in: Circle(),
                interactive: true,
                // Subtle: the glyph itself already carries the accent
                // colour, so the surface only needs to whisper it.
                tint: isActive
                    ? settings.theme.accent.opacity(0.12)
                    : nil
            )
        } else {
            content
        }
    }
}

// MARK: - Glass chip

/// Status and context: "Составлено Селеной", "Ничего не играет". Quiet by
/// default — a chip that shouts competes with the headline under it.
struct BubbleChip<Trailing: View>: View {
    let title: String
    var isProminent = true
    /// Internal, not fileprivate: a fileprivate stored property drags the
    /// whole memberwise initialiser down with it, and callers in other
    /// files lose the trailing-closure form.
    var hasTrailing = true
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: BubbleSpacing.s) {
            Text(title)
                .font(BubbleType.chip)
                .fontWeight(isProminent ? .semibold : .medium)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isProminent ? .primary : .secondary)
            trailing()
        }
        .padding(.leading, BubbleSpacing.m)
        .padding(.trailing, hasTrailing ? BubbleSpacing.xs : BubbleSpacing.m)
        .padding(.vertical, BubbleSpacing.xs + 2)
        .adaptiveGlass(in: Capsule(style: .continuous))
        .opacity(isProminent ? 1 : 0.75)
    }
}

extension BubbleChip where Trailing == EmptyView {
    init(title: String, isProminent: Bool = true) {
        self.init(
            title: title,
            isProminent: isProminent,
            hasTrailing: false
        ) { EmptyView() }
    }
}

// MARK: - Primary call to action

/// The one prominent verb on a screen. Idle Home has exactly one of
/// these; adding a second is what made the empty state read as clutter.
struct BubbleCallToAction: View {
    let title: String
    var systemImage: String = "play.fill"
    var height: CGFloat = 54
    var isBusy = false
    let action: () -> Void

    @Environment(AppSettings.self) private var settings

    var body: some View {
        Button(action: action) {
            HStack(spacing: BubbleSpacing.s) {
                if isBusy {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .bold))
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, BubbleSpacing.xxl)
            .frame(height: height)
            .frame(minWidth: 0)
            .background(settings.theme.accent, in: Capsule(style: .continuous))
        }
        .buttonStyle(BubblePressStyle())
        .disabled(isBusy)
        .accessibilityLabel(title)
    }
}

// MARK: - Shape language

/// The four rules the interface is meant to teach without explanation:
/// a musical context is a circle, media artwork is a squircle, an action
/// is a circle, chrome is a capsule. Stated once here so it cannot drift
/// across dozens of call sites.
enum BubbleShapeLanguage {
    /// Station, artist, mood, mix, recommendation.
    static var context: Circle { Circle() }

    /// Album, track and playlist artwork.
    static func media(size: CGFloat) -> RoundedRectangle {
        RoundedRectangle(
            cornerRadius: BubbleRadius.artwork(for: size),
            style: .continuous
        )
    }

    /// Play, like, shuffle, more, download.
    static var action: Circle { Circle() }

    /// Tab bar, mini player, status, search, chips.
    static var chrome: Capsule { Capsule(style: .continuous) }
}

extension View {
    /// Routes a bubble through the shared surface instead of hand-rolling
    /// `.background(in: Circle())` + `.overlay(stroke)` + `.shadow`, which
    /// is how three "hero" bubbles end up looking like three systems.
    func bubbleSurface<S: Shape>(
        _ shape: S,
        fill: BubbleFill = .chrome,
        elevation: BubbleElevation = .resting
    ) -> some View {
        BubbleSurface(shape: shape, fill: fill, elevation: elevation) {
            self
        }
    }
}
