import SwiftUI

/// A thin Gravity UI overlay on Home — not a second design system.
///
/// Tokens follow Gravity's dark theme (`#FFBE5C` brand, 8 pt controls,
/// 4 pt labels, 85% / 45% type). Artwork squircles, context tiles and
/// the player stay on Bubble. Home is the only call site on purpose:
/// if the trial reads wrong on a device, deleting this file and the
/// three Home bindings is the rollback.
enum GravityTokens {
    /// Gravity brand / `Button view=action`.
    static let brand = Color(red: 1, green: 190 / 255, blue: 92 / 255)
    /// Gravity info blue `#4CA0FF`, used as a quiet card accent, not as a second CTA.
    static let info = Color(red: 76 / 255, green: 160 / 255, blue: 1)
    static let labelRadius: CGFloat = 4
    static let controlRadius: CGFloat = 8
    static let textPrimaryOpacity: Double = 0.85
    static let textSecondaryOpacity: Double = 0.45

    static func genericSurface(isDark: Bool) -> Color {
        isDark
            ? Color(red: 59 / 255, green: 58 / 255, blue: 66 / 255)
            : Color(red: 243 / 255, green: 242 / 255, blue: 245 / 255)
    }

    static func labelFill(isProminent: Bool) -> Color {
        brand.opacity(isProminent ? 0.22 : 0.12)
    }
}

/// Gravity `Button view=action`: solid brand, black ink, 8 pt corners.
struct GravityActionButton: View {
    var systemImage: String?
    var title: String?
    var height: CGFloat = 48
    var compact = false
    var isBusy = false
    var isEnabled = true
    let accessibilityLabel: String
    let action: () -> Void

    private var resolvedHeight: CGFloat {
        compact ? 32 : height
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: BubbleSpacing.s) {
                if isBusy {
                    ProgressView()
                        .tint(.black)
                        .controlSize(.small)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: glyphSize, weight: .bold))
                }
                if let title {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.black)
            .padding(.horizontal, title == nil ? 0 : BubbleSpacing.l)
            .frame(
                width: title == nil ? resolvedHeight * 1.12 : nil,
                height: resolvedHeight
            )
            .frame(minWidth: minWidth)
            .background(
                GravityTokens.brand,
                in: RoundedRectangle(
                    cornerRadius: GravityTokens.controlRadius,
                    style: .continuous
                )
            )
        }
        .buttonStyle(BubblePressStyle())
        .disabled(!isEnabled || isBusy)
        .opacity(isEnabled ? 1 : 0.4)
        .frame(
            minWidth: BubbleMetrics.minimumTapTarget,
            minHeight: BubbleMetrics.minimumTapTarget
        )
        .accessibilityLabel(accessibilityLabel)
    }

    private var glyphSize: CGFloat {
        (resolvedHeight * 0.34).rounded()
    }

    private var minWidth: CGFloat {
        if title == nil {
            return resolvedHeight
        }
        return compact ? 92 : 0
    }
}
