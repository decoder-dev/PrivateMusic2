import Foundation

enum WatchL10n {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}
