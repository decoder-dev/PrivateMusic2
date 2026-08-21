import SwiftUI

/// Fixed geometry for the Медиатека shelves (playlists, albums).
///
/// Both shelves are a horizontal `ScrollView` nested inside the library's
/// `LazyVStack`. A lazy row has no intrinsic height, so it adopts whatever
/// height the surrounding chrome proposes. Once the library search field moved
/// into an always-visible `navigationBarDrawer` and iOS 26.0 devices switched
/// to the system `TabView`, that proposal squeezed the cards down to their
/// captions and the shelf read as a row of text tabs under the title.
///
/// Every dimension below is resolved up front — artwork, caption and the
/// scroll row itself — so a card can never lose its artwork, whatever the
/// navigation chrome proposes.
enum LibraryShelfMetrics {
    /// Square artwork edge of a shelf card.
    static let artworkSize: CGFloat = 136
    static let cardSpacing: CGFloat = 14
    /// Gap between artwork and the title/subtitle block.
    static let captionSpacing: CGFloat = 8
    /// Two lines at the default text size (title + count/artist).
    /// Callers scale this with Dynamic Type so accessibility sizes grow
    /// the caption instead of clipping it.
    static let captionHeight: CGFloat = 40
    /// Slack around the row for the pressed-card scale effect.
    static let shelfPadding: CGFloat = 2
    /// Breathing room between the navigation chrome and the first section.
    static let contentTopPadding: CGFloat = 10
    /// Gap below a whole section (shelf, «Слушать позже»).
    static let sectionSpacing: CGFloat = 24
    /// Gap between a section header and the rows underneath it.
    static let headerSpacing: CGFloat = 8

    static var cardWidth: CGFloat { artworkSize }

    static var cardHeight: CGFloat {
        artworkSize + captionSpacing + captionHeight
    }

    static var shelfHeight: CGFloat { cardHeight + shelfPadding * 2 }

    /// Share of a card occupied by artwork. Guards the regression: a shelf
    /// dominated by its caption is the text-tab layout users reported.
    static var artworkHeightRatio: CGFloat { artworkSize / cardHeight }

    /// 136 on phone; larger on iPad via AdaptiveLayout (~18% width, cap 220).
    static func artworkSize(for width: CGFloat) -> CGFloat {
        guard AdaptiveLayout.isRegularWidth(width) else {
            return artworkSize
        }
        return AdaptiveLayout.shelfCardWidth(
            for: width,
            compactMax: artworkSize,
            regularMax: AdaptiveLayout.regularCardWidthCap
        )
    }

    static func cardWidth(for width: CGFloat) -> CGFloat {
        artworkSize(for: width)
    }

    static func cardHeight(
        for width: CGFloat,
        captionHeight: CGFloat = captionHeight
    ) -> CGFloat {
        artworkSize(for: width) + captionSpacing + captionHeight
    }

    static func shelfHeight(
        for width: CGFloat,
        captionHeight: CGFloat = captionHeight
    ) -> CGFloat {
        cardHeight(for: width, captionHeight: captionHeight) + shelfPadding * 2
    }
}

extension View {
    /// Separates one library section from the next. The library's outer
    /// `LazyVStack` runs at zero spacing because the track rows live in it
    /// too, so sections carry their own gap.
    func librarySectionSpacing() -> some View {
        padding(.bottom, LibraryShelfMetrics.sectionSpacing)
    }
}
