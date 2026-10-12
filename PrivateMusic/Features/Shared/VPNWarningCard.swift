import SwiftUI

/// Shown only for a failed network operation, alongside its retry action.
struct VPNWarningCard: View {
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.text("vpn.connection_failed"), systemImage: "wifi.exclamationmark")
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            VPNConnectionAdvice()
            Button(L10n.text("action.retry"), action: retry)
                .buttonStyle(PremiumSecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .premiumCard()
        .padding(.horizontal, PremiumLayout.screenPadding)
        .padding(.vertical, 6)
    }
}

struct VPNConnectionAdvice: View {
    @State private var showsInstructions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text("vpn.warning_short"))
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.text("vpn.how_to_disable")) { showsInstructions = true }
                .font(.footnote.weight(.semibold))
                .frame(minHeight: PremiumLayout.minimumTapTarget, alignment: .leading)
                .buttonStyle(.plain)
        }
        .sheet(isPresented: $showsInstructions) { VPNInstructionsView() }
    }
}

struct VPNInstructionsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AppForm {
                Section {
                    Text(L10n.text("vpn.instructions"))
                    Text(L10n.text("vpn.instructions_note"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(L10n.text("vpn.how_to_disable"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("action.close")) { dismiss() }
                }
            }
        }
    }
}
