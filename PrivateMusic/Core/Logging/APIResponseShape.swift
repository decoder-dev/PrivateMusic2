import Foundation

/// Reduces a JSON response to its structure — keys and value types, never
/// values — so a developer can record what VK actually returns (and turn it
/// into test fixtures) without capturing titles, URLs, tokens or ids.
enum APIResponseShape {
    static let maximumArrayItems = 2
    static let maximumDepth = 10
    static let maximumLength = 6_000

    static func skeleton(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) else { return nil }
        let reduced = reduce(root, depth: 0)
        guard JSONSerialization.isValidJSONObject(reduced),
              let output = try? JSONSerialization.data(
                withJSONObject: reduced,
                options: [.sortedKeys]
              ),
              let text = String(data: output, encoding: .utf8)
        else { return nil }
        return text.count > maximumLength
            ? String(text.prefix(maximumLength)) + "…"
            : text
    }

    private static func reduce(_ value: Any, depth: Int) -> Any {
        if depth >= maximumDepth { return "<depth>" }
        switch value {
        case let object as [String: Any]:
            return object.mapValues { reduce($0, depth: depth + 1) }
        case let array as [Any]:
            return array.prefix(maximumArrayItems).map {
                reduce($0, depth: depth + 1)
            }
        case is String:
            return "<string>"
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            }
            return CFNumberIsFloatType(number) ? 0.5 : 0
        default:
            return NSNull()
        }
    }
}
