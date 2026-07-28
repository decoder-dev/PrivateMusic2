import Foundation

struct LyricLine: Sendable, Equatable, Identifiable {
    let time: TimeInterval
    let text: String

    var id: String { "\(time)-\(text)" }
}

struct Lyrics: Sendable, Equatable {
    let text: String
    let source: String
    let lines: [LyricLine]

    init(
        text: String,
        source: String,
        lines: [LyricLine] = []
    ) {
        self.text = text
        self.source = source
        self.lines = lines
    }
}
