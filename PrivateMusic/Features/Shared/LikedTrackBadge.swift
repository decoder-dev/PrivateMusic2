import SwiftUI

struct LikedTrackBadge: View {
    enum Style {
        case compact
        case artwork
    }

    @Environment(MusicLibraryStore.self) private var libraryStore
    @Environment(SessionStore.self) private var sessionStore
    let track: Track
    var style: Style = .compact

    var body: some View {
        if libraryStore.isLiked(
            track,
            currentUserID: sessionStore.session?.userID
        ) {
            Image(systemName: "heart.fill")
                .font(style == .artwork ? .caption.weight(.bold) : .caption2)
                .foregroundStyle(style == .artwork ? Color.white : Color.accentColor)
                .padding(style == .artwork ? 7 : 0)
                .background {
                    if style == .artwork {
                        Circle().fill(.black.opacity(0.56))
                    }
                }
                .accessibilityLabel(L10n.text("track_is_in_your_library"))
        }
    }
}
