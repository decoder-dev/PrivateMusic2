import SwiftUI

/// Short-lived "Removed · Undo" bar. The owner decides when it appears and
/// what undoing means; this view only draws it and reports the tap.
struct UndoBanner: View {
    let message: String
    let actionTitle: String
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.subheadline)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(action: onUndo) {
                Text(actionTitle)
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: PremiumLayout.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}
