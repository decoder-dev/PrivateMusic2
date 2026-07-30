import SwiftUI

struct EmptyStateView: View {
    @EnvironmentObject private var settings: AppSettings
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 46, weight: .medium))
                .foregroundStyle(settings.theme.accent)
            Text(L10n.text(title))
                .font(.title3.bold())
            Text(L10n.text(description))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
