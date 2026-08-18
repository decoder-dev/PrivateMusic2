import Foundation

/// Which search field chrome Search uses. System Liquid Glass `.searchable`
/// must not run alongside the legacy floating dock — they stack and overlap
/// the mini player on the Search tab.
enum SearchChromePolicy {
    static func usesSystemSearchChrome(
        isIOS26OrLater: Bool,
        classicChrome: Bool
    ) -> Bool {
        isIOS26OrLater && !classicChrome
    }
}
