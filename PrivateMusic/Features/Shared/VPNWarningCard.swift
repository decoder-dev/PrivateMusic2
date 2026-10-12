import SwiftUI

struct VPNWarningCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let dismiss: () -> Void

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        Text(L10n.text("vpn.warning_title"))
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        closeButton
                    }
                    Text(L10n.text("vpn.warning_short"))
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.shield")
                        .foregroundStyle(BubbleGamut.warning.color)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("vpn.warning_title")).font(.subheadline.weight(.semibold))
                        Text(L10n.text("vpn.warning_message"))
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    closeButton
                }
            }
        }
        .padding(12)
        .premiumCard()
        .padding(.horizontal, PremiumLayout.screenPadding)
        .padding(.vertical, 6)
    }

    private var closeButton: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark").font(.caption.weight(.semibold))
                .frame(width: PremiumLayout.minimumTapTarget, height: PremiumLayout.minimumTapTarget)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text("vpn.dismiss_warning"))
    }
}
