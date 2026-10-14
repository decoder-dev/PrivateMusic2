import SwiftUI

struct OfflineLibrarySummary: View {
    @Environment(OfflineTrackStore.self) private var store
    @Environment(NetworkMonitor.self) private var network
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if OfflineDownloadsFeature.showsControls {
            // One disk-backed record pass for both count and bytes.
            let records = store.availableRecords
            let bytes = records.reduce(Int64(0)) { $0 + $1.byteCount }
            NavigationLink { OfflineDownloadsView() } label: {
                HStack(spacing: BubbleSpacing.m) {
                    Image(systemName: network.state == .offline ? "wifi.slash" : "arrow.down.circle")
                        .font(.title3).foregroundStyle(settings.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text(network.state == .offline ? "offline.summary.disconnected" : "offline.summary.title"))
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text(L10n.format("offline.summary.detail", L10n.trackCount(records.count),
                                         ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .padding(BubbleSpacing.m)
                .frame(maxWidth: .infinity, minHeight: PremiumLayout.minimumTapTarget, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: PremiumLayout.cardRadius))
                .contentShape(Rectangle())
            }
            .buttonStyle(PremiumPressStyle())
            .accessibilityElement(children: .combine)
        }
    }
}
