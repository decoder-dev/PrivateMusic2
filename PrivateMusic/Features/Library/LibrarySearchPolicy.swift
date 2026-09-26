import Foundation

enum LibrarySearchPolicy {
    static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func allowsContinuation(query: String) -> Bool {
        normalized(query).isEmpty
    }
}

struct LibrarySearchRequest: Equatable {
    let query: String
    let revision: Int
}
