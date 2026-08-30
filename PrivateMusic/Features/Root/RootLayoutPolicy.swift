import SwiftUI

/// Which root container the app draws: the iPad sidebar, or tabs.
///
/// `horizontalSizeClass == .regular` is not "this is an iPad". A Plus or
/// Pro Max iPhone reports regular width in landscape, so deciding on the
/// size class alone swapped a phone from tabs to an iPad sidebar every
/// time it was turned on its side.
///
/// That is worse than a layout surprise. The two containers are different
/// views, so SwiftUI rebuilds the whole hierarchy when the branch flips —
/// including every `NavigationStack` inside it, and with them whatever the
/// listener had pushed. A tester found it the obvious way: open Explore,
/// rotate, rotate back, and the screen is gone.
///
/// The idiom is the part that never changes mid-session; the size class
/// still has a say, so an iPad in Slide Over or a narrow split keeps the
/// tabs it should have.
enum RootLayoutPolicy {
    static func usesSidebar(
        isPad: Bool,
        horizontalSizeClass: UserInterfaceSizeClass?
    ) -> Bool {
        isPad && horizontalSizeClass == .regular
    }
}
