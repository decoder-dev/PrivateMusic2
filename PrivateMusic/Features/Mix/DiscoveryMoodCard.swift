import SwiftUI

/// Original editorial artwork belongs to moods, never to an artist or album.
struct DiscoveryMoodCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let mood: MixMoodPreference
    let width: CGFloat
    var isLoading = false
    var isSelected = false
    let action: () -> Void

    static func artworkName(for mood: MixMoodPreference) -> String {
        switch mood {
        case .any, .energetic: "DiscoveryEnergy"
        case .calm: "DiscoveryCalm"
        case .sad: "DiscoveryRain"
        case .joyful: "DiscoverySun"
        case .love: "DiscoveryLove"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: mood.chipSymbol)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                    if isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.caption.weight(.bold))
                    }
                }
                Spacer(minLength: 20)
                Text(mood.title)
                    .font(.headline)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.white)
            .padding(14)
            .frame(width: width, alignment: .leading)
            .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 174 : 146)
            .background {
                Image(Self.artworkName(for: mood))
                    .resizable()
                    .scaledToFill()
                    .overlay {
                        LinearGradient(colors: [.black.opacity(0.12), .black.opacity(0.8)],
                                       startPoint: .top, endPoint: .bottom)
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(isSelected ? 0.85 : 0.12), lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PremiumPressStyle())
        .accessibilityLabel(mood.title)
        .accessibilityValue(isLoading ? L10n.text("loading_tracks") : "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
