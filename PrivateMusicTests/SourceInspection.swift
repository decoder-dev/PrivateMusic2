import Foundation

/// Reads app sources for conformance tests, with comments stripped so a
/// leftover `role: .search` in a comment cannot satisfy a code assertion.
enum SourceInspection {
    static func source(
        _ relativePath: String,
        filePath: String = #filePath
    ) -> String {
        let root = URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(relativePath)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func code(
        _ relativePath: String,
        filePath: String = #filePath
    ) -> String {
        stripComments(from: source(relativePath, filePath: filePath))
    }

    static func stripComments(from source: String) -> String {
        var output = ""
        output.reserveCapacity(source.count)
        var index = source.startIndex
        var inString = false
        var stringQuote: Character?
        var escaped = false

        while index < source.endIndex {
            let character = source[index]
            let nextIndex = source.index(after: index)
            let next = nextIndex < source.endIndex ? source[nextIndex] : nil

            if inString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == stringQuote {
                    inString = false
                    stringQuote = nil
                }
                index = nextIndex
                continue
            }

            if character == "\"" || character == "#" && next == "\"" {
                inString = true
                stringQuote = "\""
                output.append(character)
                index = nextIndex
                continue
            }

            if character == "/", next == "/" {
                while index < source.endIndex, source[index] != "\n" {
                    index = source.index(after: index)
                }
                continue
            }

            if character == "/", next == "*" {
                index = source.index(after: nextIndex)
                while index < source.endIndex {
                    let blockCharacter = source[index]
                    let blockNextIndex = source.index(after: index)
                    let blockNext = blockNextIndex < source.endIndex
                        ? source[blockNextIndex]
                        : nil
                    if blockCharacter == "*", blockNext == "/" {
                        index = source.index(after: blockNextIndex)
                        break
                    }
                    index = blockNextIndex
                }
                continue
            }

            output.append(character)
            index = nextIndex
        }

        return output
    }
}
