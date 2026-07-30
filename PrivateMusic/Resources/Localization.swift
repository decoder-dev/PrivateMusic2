import Foundation

enum L10n {
    static func text(
        _ key: String,
        comment: String = ""
    ) -> String {
        NSLocalizedString(
            key,
            tableName: nil,
            bundle: .main,
            value: key,
            comment: comment
        )
    }

    static func format(
        _ key: String,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: text(key),
            locale: Locale.current,
            arguments: arguments
        )
    }

    static func trackCount(_ count: Int) -> String {
        String.localizedStringWithFormat(
            text("tracks.count"),
            count
        )
    }

    static func playlistCount(_ count: Int) -> String {
        String.localizedStringWithFormat(
            text("playlists.count"),
            count
        )
    }

    static func minutes(_ count: Int) -> String {
        String.localizedStringWithFormat(
            text("minutes.count"),
            count
        )
    }
}
