import SwiftUI

struct EmptyStateView: View {
    @Environment(AppSettings.self) private var settings
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 46, weight: .medium))
                .foregroundStyle(settings.theme.accent)
                .accessibilityHidden(true)
            Text(L10n.text(title))
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.text(description))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
