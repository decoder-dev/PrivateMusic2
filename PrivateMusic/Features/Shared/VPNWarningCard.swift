import SwiftUI

struct VPNWarningCard: View {
    let dismiss: () -> Void

    var body: some View {
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
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: PremiumLayout.minimumTapTarget, height: PremiumLayout.minimumTapTarget)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("vpn.dismiss_warning"))
        }
        .padding(12)
        .premiumCard()
        .padding(.horizontal, PremiumLayout.screenPadding)
        .padding(.vertical, 6)
    }
}
